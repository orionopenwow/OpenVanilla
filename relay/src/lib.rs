//! openvanilla-relay: lets players reach community hosts that sit behind NAT.
//!
//! * Host agent keeps one control WebSocket open: `GET /agent` (`Authorization: Bearer <directory
//!   token>`, `X-Host-Id: <host_id>`). JSON control messages, see [`Ctrl`].
//! * For each player connection the relay sends `{"open":id,"port":p}` (plus `"e2e":1` when the player
//!   asked for an end-to-end sealed stream with `?e2e=1`); the agent dials its local
//!   realmd/mangosd and opens `GET /agent/stream/<id>` (same headers); binary frames = TCP bytes.
//! * Players open `GET /h/<host_id>/ws/3724` or `/ws/8085` (optional `?invite=<code>`).
//!
//! The relay never dials anything itself: it only pipes two WebSockets, so it cannot be turned
//! into an open proxy. Player IPs are only ever logged as salted hashes.

use std::collections::HashMap;
use std::future::Future;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use tokio::sync::{mpsc, oneshot, watch, Notify};

pub const PORTS: [u16; 2] = [3724, 8085];

// ---------------------------------------------------------------- config

#[derive(Clone, Debug)]
pub struct Limits {
    pub max_streams: usize,
    pub bytes_per_sec: u64,
    pub daily_bytes: u64,
    pub stream_idle: Duration,
    pub ctrl_idle: Duration,
    pub open_timeout: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_streams: 64,
            bytes_per_sec: 256 * 1024,
            daily_bytes: 20 * 1024 * 1024 * 1024,
            stream_idle: Duration::from_secs(900),
            ctrl_idle: Duration::from_secs(90),
            open_timeout: Duration::from_secs(10),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Config {
    pub bind: String,
    pub limits: Limits,
    /// `host_id token_sha256_hex [public|private]` per line.
    pub allow_file: Option<PathBuf>,
    /// Central verify endpoint, e.g. `https://play.openvanilla.app/api/directory/verify`.
    pub verify_url: Option<String>,
    /// Shared secret sent as `Authorization: Bearer` to the verify endpoint.
    pub verify_secret: Option<String>,
    /// Take the client address from `X-Forwarded-For` (only behind our own Caddy).
    pub trust_proxy: bool,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Config> {
        fn env<T: std::str::FromStr>(k: &str) -> Option<T> {
            std::env::var(k).ok().and_then(|v| v.parse().ok())
        }
        let d = Limits::default();
        let cfg = Config {
            bind: std::env::var("RELAY_BIND").unwrap_or_else(|_| "0.0.0.0:8080".into()),
            limits: Limits {
                max_streams: env("RELAY_MAX_STREAMS").unwrap_or(d.max_streams),
                bytes_per_sec: env::<u64>("RELAY_KBPS").map(|k| k * 1024).unwrap_or(d.bytes_per_sec),
                daily_bytes: env::<u64>("RELAY_DAILY_GB")
                    .map(|g| g * 1024 * 1024 * 1024)
                    .unwrap_or(d.daily_bytes),
                stream_idle: env("RELAY_STREAM_IDLE_SECS").map(Duration::from_secs).unwrap_or(d.stream_idle),
                ctrl_idle: env("RELAY_CTRL_IDLE_SECS").map(Duration::from_secs).unwrap_or(d.ctrl_idle),
                open_timeout: env("RELAY_OPEN_TIMEOUT_SECS").map(Duration::from_secs).unwrap_or(d.open_timeout),
            },
            allow_file: std::env::var("RELAY_ALLOW_FILE").ok().map(PathBuf::from),
            verify_url: std::env::var("RELAY_VERIFY_URL").ok().filter(|s| !s.is_empty()),
            verify_secret: std::env::var("RELAY_VERIFY_SECRET").ok().filter(|s| !s.is_empty()),
            trust_proxy: std::env::var("RELAY_TRUST_PROXY").map(|v| v == "1").unwrap_or(false),
        };
        if cfg.allow_file.is_none() && cfg.verify_url.is_none() {
            anyhow::bail!("set RELAY_VERIFY_URL and/or RELAY_ALLOW_FILE");
        }
        Ok(cfg)
    }
}

// ---------------------------------------------------------------- helpers

pub fn sha256_hex(s: &str) -> String {
    hex::encode(Sha256::digest(s.as_bytes()))
}

pub fn valid_host_id(s: &str) -> bool {
    s.len() == 16 && s.bytes().all(|b| matches!(b, b'a'..=b'z' | b'2'..=b'7'))
}

fn valid_invite(s: &str) -> bool {
    s.len() == 10 && s.bytes().all(|b| matches!(b, b'a'..=b'z' | b'A'..=b'Z' | b'2'..=b'7'))
}

fn unix_day() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() / 86400).unwrap_or(0)
}

// ---------------------------------------------------------------- auth

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Visibility {
    Public,
    Private,
}

struct Verifier {
    allow: HashMap<String, (String, Visibility)>,
    url: Option<String>,
    secret: Option<String>,
    http: reqwest::Client,
    cache: Mutex<HashMap<(String, String), (Instant, Visibility)>>,
}

#[derive(Deserialize)]
struct VerifyReply {
    ok: bool,
    #[serde(default)]
    visibility: Option<String>,
}

impl Verifier {
    fn new(cfg: &Config) -> anyhow::Result<Verifier> {
        let mut allow = HashMap::new();
        if let Some(p) = &cfg.allow_file {
            for line in std::fs::read_to_string(p)?.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                let f: Vec<&str> = line.split_whitespace().collect();
                if f.len() < 2 || !valid_host_id(f[0]) || f[1].len() != 64 {
                    anyhow::bail!("bad allow-file line: {line}");
                }
                let vis = if f.get(2) == Some(&"private") { Visibility::Private } else { Visibility::Public };
                allow.insert(f[0].to_string(), (f[1].to_ascii_lowercase(), vis));
            }
        }
        Ok(Verifier {
            allow,
            url: cfg.verify_url.clone(),
            secret: cfg.verify_secret.clone(),
            http: reqwest::Client::builder().timeout(Duration::from_secs(5)).build()?,
            cache: Mutex::new(HashMap::new()),
        })
    }

    /// `fresh` skips the 60 s cache (periodic re-check of live control sockets).
    async fn verify(&self, host_id: &str, token_sha: &str, fresh: bool) -> Option<Visibility> {
        if let Some((sha, vis)) = self.allow.get(host_id) {
            return (sha == token_sha).then_some(*vis);
        }
        let url = self.url.as_ref()?;
        let key = (host_id.to_string(), token_sha.to_string());
        if !fresh {
            if let Some((t, v)) = self.cache.lock().unwrap().get(&key) {
                if t.elapsed() < Duration::from_secs(60) {
                    return Some(*v);
                }
            }
        }
        let mut req = self.http.get(url).query(&[("host_id", host_id), ("token_sha", token_sha)]);
        if let Some(s) = &self.secret {
            req = req.bearer_auth(s);
        }
        let reply: VerifyReply = match req.send().await {
            Ok(r) if r.status().is_success() => r.json().await.ok()?,
            Ok(_) => return None,
            Err(e) => {
                tracing::warn!(error = %e, "verify endpoint unreachable");
                return None;
            }
        };
        if !reply.ok {
            self.cache.lock().unwrap().remove(&key);
            return None;
        }
        let vis = if reply.visibility.as_deref() == Some("private") { Visibility::Private } else { Visibility::Public };
        self.cache.lock().unwrap().insert(key, (Instant::now(), vis));
        Some(vis)
    }
}

fn bearer(h: &HeaderMap) -> Option<(String, String)> {
    let tok = h.get("authorization")?.to_str().ok()?.strip_prefix("Bearer ")?.trim();
    let id = h.get("x-host-id")?.to_str().ok()?.trim();
    if tok.is_empty() || tok.len() > 512 || !valid_host_id(id) {
        return None;
    }
    Some((id.to_string(), sha256_hex(tok)))
}

// ---------------------------------------------------------------- usage / limits

struct Bucket {
    tokens: f64,
    last: Instant,
}

/// Per-host usage; outlives agent reconnects so the daily cap cannot be reset by reconnecting.
pub struct Usage {
    rate: f64,
    bucket: tokio::sync::Mutex<Bucket>,
    day: Mutex<(u64, u64)>,
    daily: u64,
}

impl Usage {
    fn new(l: &Limits) -> Usage {
        let rate = l.bytes_per_sec.max(1) as f64;
        Usage {
            rate,
            bucket: tokio::sync::Mutex::new(Bucket { tokens: rate, last: Instant::now() }),
            day: Mutex::new((unix_day(), 0)),
            daily: l.daily_bytes,
        }
    }

    pub fn over_daily(&self) -> bool {
        let mut d = self.day.lock().unwrap();
        let today = unix_day();
        if d.0 != today {
            *d = (today, 0);
        }
        d.1 >= self.daily
    }

    /// Count `n` bytes against the daily cap and wait for the token bucket. `false` = cap hit.
    async fn consume(&self, n: usize) -> bool {
        {
            let mut d = self.day.lock().unwrap();
            let today = unix_day();
            if d.0 != today {
                *d = (today, 0);
            }
            if d.1 >= self.daily {
                return false;
            }
            d.1 += n as u64;
        }
        // Holding the async mutex while sleeping serialises the host's streams: fair enough and
        // keeps the aggregate at `rate`.
        let mut b = self.bucket.lock().await;
        let now = Instant::now();
        b.tokens = (b.tokens + now.duration_since(b.last).as_secs_f64() * self.rate).min(self.rate);
        b.last = now;
        b.tokens -= n as f64;
        if b.tokens < 0.0 {
            tokio::time::sleep(Duration::from_secs_f64(-b.tokens / self.rate)).await;
        }
        true
    }
}

// ---------------------------------------------------------------- metrics

#[derive(Default)]
pub struct Metrics {
    agents_total: AtomicU64,
    agent_auth_fail: AtomicU64,
    streams_total: AtomicU64,
    rej_offline: AtomicU64,
    rej_limit: AtomicU64,
    rej_daily: AtomicU64,
    rej_invite: AtomicU64,
    rej_timeout: AtomicU64,
    bytes_to_player: AtomicU64,
    bytes_to_host: AtomicU64,
    idle_closed: AtomicU64,
}

// ---------------------------------------------------------------- state

struct Host {
    gen: u64,
    ctrl: mpsc::UnboundedSender<String>,
    kick: Arc<Notify>,
    token_sha: String,
    vis: Visibility,
    streams: HashMap<u64, Arc<Notify>>,
    pending: HashMap<u64, oneshot::Sender<WebSocket>>,
    invites: HashMap<u64, oneshot::Sender<bool>>,
}

pub struct Inner {
    cfg: Config,
    verifier: Verifier,
    hosts: Mutex<HashMap<String, Host>>,
    usage: Mutex<HashMap<String, Arc<Usage>>>,
    /// open player streams per (hashed) address, all hosts: one address can't fill a host's slots
    per_ip: Mutex<HashMap<String, usize>>,
    metrics: Metrics,
    next_id: AtomicU64,
    salt: [u8; 16],
    started: Instant,
    shutdown: watch::Receiver<bool>,
}

#[derive(Clone)]
pub struct Relay(Arc<Inner>);

impl Relay {
    fn usage(&self, host_id: &str) -> Arc<Usage> {
        self.0
            .usage
            .lock()
            .unwrap()
            .entry(host_id.to_string())
            .or_insert_with(|| Arc::new(Usage::new(&self.0.cfg.limits)))
            .clone()
    }

    fn ip_hash(&self, peer: SocketAddr, h: &HeaderMap) -> String {
        let ip = if self.0.cfg.trust_proxy {
            h.get("x-forwarded-for")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.split(',').next())
                .map(|s| s.trim().to_string())
                .unwrap_or_else(|| peer.ip().to_string())
        } else {
            peer.ip().to_string()
        };
        // Salt is random per process and mixed with the day: hashes cannot be linked across days.
        let mut d = Sha256::new();
        d.update(self.0.salt);
        d.update(unix_day().to_le_bytes());
        d.update(ip.as_bytes());
        hex::encode(&d.finalize()[..6])
    }

    fn now_ms(&self) -> u64 {
        self.0.started.elapsed().as_millis() as u64
    }
}

pub fn router(cfg: Config, shutdown: watch::Receiver<bool>) -> anyhow::Result<Router> {
    let mut salt = [0u8; 16];
    rand::Rng::fill(&mut rand::thread_rng(), &mut salt);
    let inner = Inner {
        verifier: Verifier::new(&cfg)?,
        cfg,
        hosts: Mutex::new(HashMap::new()),
        usage: Mutex::new(HashMap::new()),
        per_ip: Mutex::new(HashMap::new()),
        metrics: Metrics::default(),
        next_id: AtomicU64::new(1),
        salt,
        started: Instant::now(),
        shutdown,
    };
    Ok(Router::new()
        .route("/agent", get(agent_ctrl))
        .route("/agent/stream/{id}", get(agent_stream))
        .route("/h/{host_id}/ws/{port}", get(player))
        .route("/metrics", get(metrics))
        .route("/healthz", get(|| async { "ok" }))
        .with_state(Relay(Arc::new(inner))))
}

/// Serve until `signal` resolves, then tell every live socket to close and drain.
pub async fn serve(
    listener: tokio::net::TcpListener,
    cfg: Config,
    signal: impl Future<Output = ()> + Send + 'static,
) -> anyhow::Result<()> {
    let (tx, rx) = watch::channel(false);
    let app = router(cfg, rx)?;
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(async move {
            signal.await;
            let _ = tx.send(true);
        })
        .await?;
    tracing::info!("relay stopped");
    Ok(())
}

// ---------------------------------------------------------------- control socket

#[derive(Deserialize, Default)]
#[serde(default)]
struct Ctrl {
    ping: Option<u64>,
    close: Option<u64>,
    invite_ok: Option<u64>,
    invite_no: Option<u64>,
}

async fn agent_ctrl(State(r): State<Relay>, headers: HeaderMap, ws: WebSocketUpgrade) -> Response {
    let Some((host_id, sha)) = bearer(&headers) else {
        r.0.metrics.agent_auth_fail.fetch_add(1, Relaxed);
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let Some(vis) = r.0.verifier.verify(&host_id, &sha, false).await else {
        r.0.metrics.agent_auth_fail.fetch_add(1, Relaxed);
        tracing::info!(host_id, "agent auth refused");
        return StatusCode::UNAUTHORIZED.into_response();
    };
    ws.max_message_size(MAX_CTRL_MESSAGE)
        .max_frame_size(MAX_CTRL_MESSAGE)
        .on_upgrade(move |s| ctrl_session(r, s, host_id, sha, vis))
}

async fn ctrl_session(r: Relay, ws: WebSocket, host_id: String, sha: String, vis: Visibility) {
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let kick = Arc::new(Notify::new());
    let gen = r.0.next_id.fetch_add(1, Relaxed);
    {
        let mut hosts = r.0.hosts.lock().unwrap();
        let new = Host {
            gen,
            ctrl: tx.clone(),
            kick: kick.clone(),
            token_sha: sha.clone(),
            vis,
            streams: HashMap::new(),
            pending: HashMap::new(),
            invites: HashMap::new(),
        };
        if let Some(old) = hosts.insert(host_id.clone(), new) {
            old.kick.notify_one();
            for n in old.streams.values() {
                n.notify_one();
            }
        }
    }
    r.0.metrics.agents_total.fetch_add(1, Relaxed);
    tracing::info!(host_id, private = (vis == Visibility::Private), "agent connected");
    let l = &r.0.cfg.limits;
    let _ = tx.send(
        serde_json::json!({"limits": {"max_streams": l.max_streams,
            "bytes_per_sec": l.bytes_per_sec, "daily_bytes": l.daily_bytes,
            "stream_idle_secs": l.stream_idle.as_secs()}})
        .to_string(),
    );
    drop(tx);

    let (mut sink, mut stream) = ws.split();
    let mut shutdown = r.0.shutdown.clone();
    let mut recheck = tokio::time::interval(Duration::from_secs(600));
    recheck.tick().await;
    let idle = l.ctrl_idle;
    let mut deadline = tokio::time::Instant::now() + idle;
    loop {
        tokio::select! {
            out = rx.recv() => match out {
                Some(t) => if sink.send(Message::text(t)).await.is_err() { break },
                None => break,
            },
            msg = stream.next() => {
                let Some(Ok(msg)) = msg else { break };
                deadline = tokio::time::Instant::now() + idle;
                let Message::Text(t) = msg else { continue };
                let Ok(c) = serde_json::from_str::<Ctrl>(&t) else { continue };
                if let Some(n) = c.ping {
                    if sink.send(Message::text(serde_json::json!({"pong": n}).to_string())).await.is_err() { break }
                }
                let mut hosts = r.0.hosts.lock().unwrap();
                let Some(h) = hosts.get_mut(&host_id).filter(|h| h.gen == gen) else { break };
                if let Some(id) = c.close { if let Some(n) = h.streams.get(&id) { n.notify_one(); } }
                if let Some(id) = c.invite_ok { if let Some(s) = h.invites.remove(&id) { let _ = s.send(true); } }
                if let Some(id) = c.invite_no { if let Some(s) = h.invites.remove(&id) { let _ = s.send(false); } }
            }
            _ = tokio::time::sleep_until(deadline) => {
                tracing::info!(host_id, "agent control idle timeout");
                break;
            }
            _ = recheck.tick() => {
                if r.0.verifier.verify(&host_id, &sha, true).await.is_none() {
                    tracing::info!(host_id, "agent token no longer valid");
                    break;
                }
            }
            _ = kick.notified() => break,
            _ = shutdown.changed() => break,
        }
    }
    let _ = sink.send(Message::Close(None)).await;
    let mut hosts = r.0.hosts.lock().unwrap();
    if hosts.get(&host_id).map(|h| h.gen) == Some(gen) {
        if let Some(h) = hosts.remove(&host_id) {
            for n in h.streams.values() {
                n.notify_one();
            }
        }
    }
    tracing::info!(host_id, "agent disconnected");
}

// ---------------------------------------------------------------- agent data stream

async fn agent_stream(
    State(r): State<Relay>,
    Path(id): Path<u64>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    let Some((host_id, sha)) = bearer(&headers) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let tx = {
        let mut hosts = r.0.hosts.lock().unwrap();
        let Some(h) = hosts.get_mut(&host_id).filter(|h| h.token_sha == sha) else {
            return StatusCode::UNAUTHORIZED.into_response();
        };
        let Some(tx) = h.pending.remove(&id) else {
            return StatusCode::NOT_FOUND.into_response();
        };
        tx
    };
    ws.max_message_size(MAX_WS_MESSAGE).max_frame_size(MAX_WS_MESSAGE).on_upgrade(move |s| async move {
        let _ = tx.send(s);
    })
}

// ---------------------------------------------------------------- player

/// Removes the stream from its host and tells the agent, whatever way the player session ends.
struct StreamGuard {
    r: Relay,
    host_id: String,
    id: u64,
    ip: String,
}

/// Player streams one address may hold open at once (per relay), and the largest WebSocket
/// message accepted (game traffic is a few KB a frame; the default 64 MiB would let a handful of
/// frames exhaust the container's memory).
const PER_IP_STREAMS: usize = 8;
const MAX_WS_MESSAGE: usize = 1 << 20;
const MAX_CTRL_MESSAGE: usize = 64 << 10;

impl Drop for StreamGuard {
    fn drop(&mut self) {
        {
            let mut pi = self.r.0.per_ip.lock().unwrap();
            if let Some(n) = pi.get_mut(&self.ip) {
                *n = n.saturating_sub(1);
                if *n == 0 {
                    pi.remove(&self.ip);
                }
            }
        }
        let mut hosts = self.r.0.hosts.lock().unwrap();
        if let Some(h) = hosts.get_mut(&self.host_id) {
            let had = h.streams.remove(&self.id).is_some();
            h.pending.remove(&self.id);
            h.invites.remove(&self.id);
            if had {
                let _ = h.ctrl.send(serde_json::json!({"close": self.id}).to_string());
            }
        }
    }
}

async fn player(
    State(r): State<Relay>,
    Path((host_id, port)): Path<(String, u16)>,
    Query(q): Query<HashMap<String, String>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    let m = &r.0.metrics;
    if !PORTS.contains(&port) || !valid_host_id(&host_id) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let ip = r.ip_hash(peer, &headers);
    // an offline (or made-up) host gets no usage record: otherwise any well-formed id grows memory
    if !r.0.hosts.lock().unwrap().contains_key(&host_id) {
        m.rej_offline.fetch_add(1, Relaxed);
        return (StatusCode::NOT_FOUND, "host offline").into_response();
    }
    let usage = r.usage(&host_id);
    if usage.over_daily() {
        m.rej_daily.fetch_add(1, Relaxed);
        return (StatusCode::TOO_MANY_REQUESTS, "host daily relay quota used").into_response();
    }
    let id = r.0.next_id.fetch_add(1, Relaxed);
    let (ctrl, vis, cancel) = {
        let mut hosts = r.0.hosts.lock().unwrap();
        let Some(h) = hosts.get_mut(&host_id) else {
            m.rej_offline.fetch_add(1, Relaxed);
            return (StatusCode::NOT_FOUND, "host offline").into_response();
        };
        if h.streams.len() >= r.0.cfg.limits.max_streams {
            m.rej_limit.fetch_add(1, Relaxed);
            tracing::info!(host_id, ip, "stream limit reached");
            return (StatusCode::SERVICE_UNAVAILABLE, "host stream limit reached").into_response();
        }
        {
            let mut pi = r.0.per_ip.lock().unwrap();
            let n = pi.entry(ip.clone()).or_insert(0);
            if *n >= PER_IP_STREAMS {
                m.rej_limit.fetch_add(1, Relaxed);
                tracing::info!(host_id, ip, "per-address stream limit reached");
                return (StatusCode::TOO_MANY_REQUESTS, "too many open streams from this address").into_response();
            }
            *n += 1;
        }
        let cancel = Arc::new(Notify::new());
        h.streams.insert(id, cancel.clone());
        (h.ctrl.clone(), h.vis, cancel)
    };
    let guard = StreamGuard { r: r.clone(), host_id: host_id.clone(), id, ip: ip.clone() };
    let wait = r.0.cfg.limits.open_timeout;

    if vis == Visibility::Private {
        let code = q.get("invite").filter(|c| valid_invite(c));
        let Some(code) = code else {
            m.rej_invite.fetch_add(1, Relaxed);
            return (StatusCode::FORBIDDEN, "invite required").into_response();
        };
        let (tx, rx) = oneshot::channel();
        if let Some(h) = r.0.hosts.lock().unwrap().get_mut(&host_id) {
            h.invites.insert(id, tx);
        }
        let _ = ctrl.send(serde_json::json!({"invite_check": code, "stream": id}).to_string());
        if !matches!(tokio::time::timeout(wait, rx).await, Ok(Ok(true))) {
            m.rej_invite.fetch_add(1, Relaxed);
            tracing::info!(host_id, ip, "invite refused");
            return (StatusCode::FORBIDDEN, "invite refused").into_response();
        }
    }

    let (tx, rx) = oneshot::channel();
    if let Some(h) = r.0.hosts.lock().unwrap().get_mut(&host_id) {
        h.pending.insert(id, tx);
    }
    // `?e2e=1`: the player's launcher seals this stream end to end (launcher/p2p/e2e.py); the agent
    // must answer the handshake. The relay itself only passes the flag along.
    let open = if q.get("e2e").map(String::as_str) == Some("1") {
        serde_json::json!({"open": id, "port": port, "e2e": 1})
    } else {
        serde_json::json!({"open": id, "port": port})
    };
    let _ = ctrl.send(open.to_string());
    let agent = match tokio::time::timeout(wait, rx).await {
        Ok(Ok(s)) => s,
        _ => {
            m.rej_timeout.fetch_add(1, Relaxed);
            return (StatusCode::BAD_GATEWAY, "host did not answer").into_response();
        }
    };
    m.streams_total.fetch_add(1, Relaxed);
    tracing::info!(host_id, stream = id, port, ip, "stream open");
    ws.max_message_size(MAX_WS_MESSAGE).max_frame_size(MAX_WS_MESSAGE).on_upgrade(move |p| async move {
        let r2 = guard.r.clone();
        pipe(&r2, p, agent, &usage, &cancel).await;
        tracing::info!(host_id = guard.host_id, stream = id, "stream closed");
        drop(guard);
    })
}

async fn pump(
    r: &Relay,
    mut from: futures_util::stream::SplitStream<WebSocket>,
    mut to: futures_util::stream::SplitSink<WebSocket, Message>,
    usage: &Usage,
    counter: &AtomicU64,
    last: &AtomicU64,
) {
    while let Some(Ok(msg)) = from.next().await {
        match msg {
            Message::Binary(b) => {
                last.store(r.now_ms(), Relaxed);
                if !usage.consume(b.len()).await {
                    break;
                }
                counter.fetch_add(b.len() as u64, Relaxed);
                if to.send(Message::Binary(b)).await.is_err() {
                    break;
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }
    let _ = to.send(Message::Close(None)).await;
}

async fn pipe(r: &Relay, player: WebSocket, agent: WebSocket, usage: &Usage, cancel: &Notify) {
    let (p_tx, p_rx) = player.split();
    let (a_tx, a_rx) = agent.split();
    let last = AtomicU64::new(r.now_ms());
    let m = &r.0.metrics;
    let idle = r.0.cfg.limits.stream_idle;
    let idle_watch = async {
        let step = (idle / 4).max(Duration::from_millis(100));
        loop {
            tokio::time::sleep(step).await;
            if r.now_ms().saturating_sub(last.load(Relaxed)) >= idle.as_millis() as u64 {
                m.idle_closed.fetch_add(1, Relaxed);
                return;
            }
        }
    };
    let mut shutdown = r.0.shutdown.clone();
    tokio::select! {
        _ = futures_util::future::join(
            pump(r, p_rx, a_tx, usage, &m.bytes_to_host, &last),
            pump(r, a_rx, p_tx, usage, &m.bytes_to_player, &last),
        ) => {}
        _ = cancel.notified() => {}
        _ = idle_watch => {}
        _ = shutdown.changed() => {}
    }
}

// ---------------------------------------------------------------- /metrics

async fn metrics(State(r): State<Relay>) -> Response {
    let m = &r.0.metrics;
    let (agents, streams) = {
        let h = r.0.hosts.lock().unwrap();
        (h.len(), h.values().map(|h| h.streams.len()).sum::<usize>())
    };
    let g = |a: &AtomicU64| a.load(Relaxed);
    let body = format!(
        "# TYPE openvanilla_relay_agents gauge\nopenvanilla_relay_agents {agents}\n\
# TYPE openvanilla_relay_streams gauge\nopenvanilla_relay_streams {streams}\n\
# TYPE openvanilla_relay_agent_connections_total counter\nopenvanilla_relay_agent_connections_total {}\n\
# TYPE openvanilla_relay_agent_auth_failures_total counter\nopenvanilla_relay_agent_auth_failures_total {}\n\
# TYPE openvanilla_relay_streams_total counter\nopenvanilla_relay_streams_total {}\n\
# TYPE openvanilla_relay_streams_rejected_total counter\n\
openvanilla_relay_streams_rejected_total{{reason=\"offline\"}} {}\n\
openvanilla_relay_streams_rejected_total{{reason=\"stream_limit\"}} {}\n\
openvanilla_relay_streams_rejected_total{{reason=\"daily_quota\"}} {}\n\
openvanilla_relay_streams_rejected_total{{reason=\"invite\"}} {}\n\
openvanilla_relay_streams_rejected_total{{reason=\"agent_timeout\"}} {}\n\
# TYPE openvanilla_relay_streams_idle_closed_total counter\nopenvanilla_relay_streams_idle_closed_total {}\n\
# TYPE openvanilla_relay_bytes_total counter\n\
openvanilla_relay_bytes_total{{dir=\"to_player\"}} {}\n\
openvanilla_relay_bytes_total{{dir=\"to_host\"}} {}\n",
        g(&m.agents_total), g(&m.agent_auth_fail), g(&m.streams_total),
        g(&m.rej_offline), g(&m.rej_limit), g(&m.rej_daily), g(&m.rej_invite), g(&m.rej_timeout),
        g(&m.idle_closed), g(&m.bytes_to_player), g(&m.bytes_to_host),
    );
    ([("content-type", "text/plain; version=0.0.4")], body).into_response()
}
