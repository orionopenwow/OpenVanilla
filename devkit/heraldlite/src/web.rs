//! Web mode: log in to a wenilla-realm service the way a browser does and get the session's game
//! credential, then reach realmd/mangosd through its `/ws/{port}` WebSocket relay.
//!
//! What the realm service does (wenilla `crates/wenilla-realm`, at the pinned commit):
//! - `POST /login` (form `username`, `password`; no CSRF token on this form) answers `303 See Other`
//!   with `Set-Cookie: wr_session=<token>` on success (`auth/local.rs`), or `200` with the login
//!   page and an error on failure. A `Location: /account/password` means the account must change
//!   its password first; every gated route then refuses until it does.
//! - `GET /api/play` (cookie-gated, `X-Requested-With: wenilla`, `no-store`) returns
//!   `{"user", "pass", "host", "realm", "char"?}`: the game account the service provisioned for
//!   this web user and its password, as the play page hands them to the wasm client
//!   (`api.rs`, `templates/play.html`). The session cookie may be rotated on any gated response.
//! - `GET /ws/{port}?host=<host>` (cookie-gated; only 3724 and 8085 are allowed) upgrades to a
//!   WebSocket that is a raw byte pipe to realmd/mangosd: one TCP read chunk = one binary frame,
//!   any frame = one write (`wenilla-host/src/ws.rs`). No framing of its own, so the game protocol
//!   runs through it unchanged.
//! - A global filter refuses state-changing requests and WebSocket upgrades labelled
//!   `Sec-Fetch-Site: cross-site` (`csrf.rs`); we send no `Sec-Fetch-*` headers.

use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};

/// The realm service's session cookie (`session.rs`).
pub const SESSION_COOKIE: &str = "wr_session";

/// A parsed `http(s)://host[:port][/base]` origin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Origin {
    pub tls: bool,
    pub host: String,
    pub port: u16,
    /// Path prefix without a trailing slash (usually empty).
    pub base: String,
}

impl Origin {
    pub fn parse(url: &str) -> Result<Origin> {
        let url = url.trim();
        let (tls, rest) = if let Some(r) = url.strip_prefix("https://") {
            (true, r)
        } else if let Some(r) = url.strip_prefix("http://") {
            (false, r)
        } else if url.contains("://") {
            bail!("web url must be http:// or https://, got {url:?}");
        } else {
            (true, url)
        };
        let (authority, path) = match rest.find('/') {
            Some(i) => (&rest[..i], &rest[i..]),
            None => (rest, ""),
        };
        if authority.is_empty() {
            bail!("web url has no host: {url:?}");
        }
        let default = if tls { 443 } else { 80 };
        let (host, port) = match authority.rsplit_once(':') {
            Some((h, p)) if !h.contains(':') || h.starts_with('[') => (
                h.trim_start_matches('[').trim_end_matches(']').to_string(),
                p.parse::<u16>()
                    .map_err(|_| anyhow!("bad port in {url:?}"))?,
            ),
            _ => (authority.to_string(), default),
        };
        let base = path.trim_end_matches('/').to_string();
        // A pasted "https://realm/login" means the realm root.
        let base = base
            .strip_suffix("/login")
            .map(str::to_string)
            .unwrap_or(base);
        Ok(Origin {
            tls,
            host,
            port,
            base,
        })
    }

    fn default_port(&self) -> bool {
        self.port == if self.tls { 443 } else { 80 }
    }

    /// `Host` header value / authority.
    pub fn authority(&self) -> String {
        if self.default_port() {
            self.host.clone()
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }

    pub fn http_url(&self) -> String {
        format!(
            "{}://{}{}",
            if self.tls { "https" } else { "http" },
            self.authority(),
            self.base
        )
    }

    pub fn ws_url(&self, path: &str) -> String {
        format!(
            "{}://{}{}{}",
            if self.tls { "wss" } else { "ws" },
            self.authority(),
            self.base,
            path
        )
    }

    pub fn path(&self, p: &str) -> String {
        format!("{}{}", self.base, p)
    }
}

// ── Transport: plain TCP or rustls ──────────────────────────────────────────────────────────────

pub enum Stream {
    Plain(TcpStream),
    Tls(Box<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>),
}

impl Stream {
    pub fn tcp(&self) -> &TcpStream {
        match self {
            Stream::Plain(s) => s,
            Stream::Tls(s) => s.get_ref(),
        }
    }
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Stream::Plain(s) => s.read(buf),
            Stream::Tls(s) => match s.read(buf) {
                // A server that closes without close_notify (common behind proxies) is EOF.
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => Ok(0),
                other => other,
            },
        }
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Stream::Plain(s) => s.write(buf),
            Stream::Tls(s) => s.write(buf),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            Stream::Plain(s) => s.flush(),
            Stream::Tls(s) => s.flush(),
        }
    }
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let mut roots = rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            // An extra PEM bundle (a corporate proxy, a staging CA): HL_CA_FILE.
            if let Ok(path) = std::env::var("HL_CA_FILE") {
                if let Ok(pem) = std::fs::read(&path) {
                    for der in pem_certs(&pem) {
                        let _ = roots.add(rustls::pki_types::CertificateDer::from(der));
                    }
                }
            }
            let provider = Arc::new(rustls::crypto::ring::default_provider());
            let config = rustls::ClientConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .expect("ring supports the default protocol versions")
                .with_root_certificates(roots)
                .with_no_client_auth();
            Arc::new(config)
        })
        .clone()
}

/// The DER bodies of every `CERTIFICATE` block in a PEM file (tiny decoder, no extra crate).
fn pem_certs(pem: &[u8]) -> Vec<Vec<u8>> {
    let text = String::from_utf8_lossy(pem);
    let mut out = Vec::new();
    let mut inside = false;
    let mut b64 = String::new();
    for line in text.lines() {
        let line = line.trim();
        if line == "-----BEGIN CERTIFICATE-----" {
            inside = true;
            b64.clear();
        } else if line == "-----END CERTIFICATE-----" {
            inside = false;
            if let Some(der) = base64_decode(&b64) {
                out.push(der);
            }
        } else if inside {
            b64.push_str(line);
        }
    }
    out
}

fn base64_decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let mut acc = 0u32;
    let mut bits = 0;
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            b'\r' | b'\n' | b' ' => continue,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// Open a TCP (and, for https/wss, TLS) connection to `origin`.
pub fn connect(origin: &Origin, timeout: Duration) -> Result<Stream> {
    let addr = (origin.host.as_str(), origin.port)
        .to_socket_addrs()
        .with_context(|| format!("resolving {}", origin.host))?
        .next()
        .ok_or_else(|| anyhow!("{} resolved to no address", origin.host))?;
    let tcp = TcpStream::connect_timeout(&addr, timeout)
        .with_context(|| format!("connecting to {}:{}", origin.host, origin.port))?;
    tcp.set_nodelay(true).ok();
    tcp.set_read_timeout(Some(timeout)).ok();
    tcp.set_write_timeout(Some(timeout)).ok();
    if !origin.tls {
        return Ok(Stream::Plain(tcp));
    }
    let name = rustls::pki_types::ServerName::try_from(origin.host.clone())
        .map_err(|e| anyhow!("bad TLS server name {:?}: {e}", origin.host))?;
    let conn = rustls::ClientConnection::new(tls_config(), name).context("starting TLS")?;
    let mut s = rustls::StreamOwned::new(conn, tcp);
    // Drive the handshake now so a certificate problem is reported as such.
    while s.conn.is_handshaking() {
        s.conn
            .complete_io(&mut s.sock)
            .with_context(|| format!("TLS handshake with {}", origin.host))?;
    }
    Ok(Stream::Tls(Box::new(s)))
}

// ── Minimal HTTP/1.1 client ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
    pub fn headers_named<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a str> + 'a {
        self.headers
            .iter()
            .filter(move |(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

/// Parse a complete HTTP/1.1 response (read to EOF on a `Connection: close` request).
pub fn parse_response(raw: &[u8]) -> Result<Response> {
    let head_end = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or_else(|| anyhow!("truncated HTTP response ({} bytes)", raw.len()))?;
    let head = std::str::from_utf8(&raw[..head_end]).context("non-UTF-8 HTTP head")?;
    let mut lines = head.split("\r\n");
    let status_line = lines.next().unwrap_or_default();
    let mut parts = status_line.splitn(3, ' ');
    let version = parts.next().unwrap_or_default();
    if !version.starts_with("HTTP/1.") {
        bail!("not an HTTP/1.x response: {status_line:?}");
    }
    let status: u16 = parts
        .next()
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| anyhow!("bad status line {status_line:?}"))?;
    let mut headers = Vec::new();
    for l in lines {
        if let Some((k, v)) = l.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
    let mut body = raw[head_end + 4..].to_vec();
    let resp_is_chunked = headers.iter().any(|(k, v)| {
        k.eq_ignore_ascii_case("transfer-encoding") && v.to_ascii_lowercase().contains("chunked")
    });
    if resp_is_chunked {
        body = dechunk(&body)?;
    } else if let Some(len) = headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.parse::<usize>().ok())
    {
        body.truncate(len);
    }
    Ok(Response {
        status,
        headers,
        body,
    })
}

fn dechunk(mut b: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let eol = b
            .windows(2)
            .position(|w| w == b"\r\n")
            .ok_or_else(|| anyhow!("truncated chunked body"))?;
        let size_line = std::str::from_utf8(&b[..eol])?;
        let size_hex = size_line.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_hex, 16)
            .map_err(|_| anyhow!("bad chunk size {size_line:?}"))?;
        b = &b[eol + 2..];
        if size == 0 {
            return Ok(out);
        }
        if b.len() < size {
            bail!("truncated chunk");
        }
        out.extend_from_slice(&b[..size]);
        b = &b[size..];
        b = b.strip_prefix(b"\r\n").unwrap_or(b);
    }
}

/// One request on a fresh connection (`Connection: close`). Redirects are not followed.
pub fn request(
    origin: &Origin,
    method: &str,
    path: &str,
    headers: &[(&str, String)],
    body: Option<(&str, &[u8])>,
    timeout: Duration,
) -> Result<Response> {
    let mut s = connect(origin, timeout)?;
    let mut req = format!(
        "{method} {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: heraldlite/{}\r\nAccept: */*\r\nConnection: close\r\n",
        origin.path(path),
        origin.authority(),
        env!("CARGO_PKG_VERSION"),
    );
    for (k, v) in headers {
        req.push_str(&format!("{k}: {v}\r\n"));
    }
    if let Some((ctype, b)) = body {
        req.push_str(&format!(
            "Content-Type: {ctype}\r\nContent-Length: {}\r\n",
            b.len()
        ));
    }
    req.push_str("\r\n");
    let mut bytes = req.into_bytes();
    if let Some((_, b)) = body {
        bytes.extend_from_slice(b);
    }
    s.write_all(&bytes)
        .with_context(|| format!("sending {method} {path}"))?;
    s.flush()?;
    let mut raw = Vec::new();
    s.read_to_end(&mut raw)
        .with_context(|| format!("reading the answer to {method} {path}"))?;
    parse_response(&raw).with_context(|| format!("{method} {path}"))
}

/// `application/x-www-form-urlencoded` encoding of one value.
pub fn form_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// The value of `name` in any `Set-Cookie` header, when the server set (not cleared) it.
pub fn cookie_from(resp: &Response, name: &str) -> Option<String> {
    let mut found = None;
    for v in resp.headers_named("set-cookie") {
        let first = v.split(';').next().unwrap_or("").trim();
        if let Some((k, val)) = first.split_once('=') {
            if k.trim() == name {
                let val = val.trim().trim_matches('"');
                found = (!val.is_empty()).then(|| val.to_string());
            }
        }
    }
    found
}

/// The play credential the service mints for the logged-in web user (`GET /api/play`).
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
pub struct PlayCredential {
    /// The game account name.
    pub user: String,
    /// The game account password (provisioned by the service; never long-lived in a browser).
    pub pass: String,
    /// The public host the client should show/dial (the relay ignores `?host=` for routing).
    pub host: String,
    /// The realm name, as realmd lists it.
    pub realm: String,
    /// A dungeon-preset character the play page jumps straight into.
    #[serde(default, rename = "char")]
    pub character: Option<String>,
}

/// A logged-in web session.
#[derive(Debug, Clone)]
pub struct WebSession {
    pub origin: Origin,
    pub cookie: String,
    pub timeout: Duration,
}

/// Recognised failure texts of the login page (`auth/local.rs`).
const LOGIN_ERRORS: &[&str] = &[
    "wrong username or password",
    "too many attempts",
    "has expired",
    "form token mismatch",
];

impl WebSession {
    /// `POST /login` and keep the session cookie.
    pub fn login(
        origin: &Origin,
        username: &str,
        password: &str,
        timeout: Duration,
    ) -> Result<WebSession> {
        let form = format!(
            "username={}&password={}",
            form_encode(username),
            form_encode(password)
        );
        let resp = request(
            origin,
            "POST",
            "/login",
            &[("Origin", origin.http_url())],
            Some(("application/x-www-form-urlencoded", form.as_bytes())),
            timeout,
        )
        .context("web login")?;
        let cookie = cookie_from(&resp, SESSION_COOKIE);
        match (resp.status, cookie) {
            (300..=399, Some(cookie)) => {
                let location = resp.header("location").unwrap_or("");
                if location.contains("/account/password") {
                    bail!("web login ok, but the account must change its password first (open {}/account/password in a browser)", origin.http_url());
                }
                Ok(WebSession {
                    origin: origin.clone(),
                    cookie,
                    timeout,
                })
            }
            (200, None) => {
                let page = resp.text().to_ascii_lowercase();
                let why = LOGIN_ERRORS
                    .iter()
                    .find(|e| page.contains(*e))
                    .copied()
                    .unwrap_or("the login page came back without a session");
                bail!("web login refused: {why}")
            }
            (status, _) => bail!(
                "web login: unexpected HTTP {status}{}",
                resp.header("location")
                    .map(|l| format!(" -> {l}"))
                    .unwrap_or_default()
            ),
        }
    }

    pub fn cookie_header(&self) -> String {
        format!("{SESSION_COOKIE}={}", self.cookie)
    }

    /// `GET /api/play`: the game credential for this session, exactly as the play page fetches it.
    pub fn play_credential(&mut self) -> Result<PlayCredential> {
        let resp = request(
            &self.origin,
            "GET",
            "/api/play",
            &[
                ("Cookie", self.cookie_header()),
                ("X-Requested-With", "wenilla".to_string()),
            ],
            None,
            self.timeout,
        )
        .context("fetching /api/play")?;
        if let Some(fresh) = cookie_from(&resp, SESSION_COOKIE) {
            self.cookie = fresh;
        }
        match resp.status {
            200 => {}
            401 => bail!("/api/play: 401, the web session was not accepted"),
            429 => bail!("/api/play: 429, rate limited (30/min per session)"),
            s @ 300..=399 => bail!(
                "/api/play: redirected ({s} -> {}); a password change or setup is pending",
                resp.header("location").unwrap_or("?")
            ),
            s => bail!(
                "/api/play: HTTP {s}: {}",
                resp.text().chars().take(200).collect::<String>()
            ),
        }
        serde_json::from_slice(&resp.body).context("/api/play: unexpected JSON")
    }

    /// The relay URL for a game port, as `transport/web.rs` builds it: `/ws/{port}?host={host}`.
    pub fn relay_url(&self, port: u16, host: &str) -> String {
        self.origin
            .ws_url(&format!("/ws/{port}?host={}", form_encode(host)))
    }
}

/// Open the relay WebSocket for one game connection.
pub fn open_relay(
    session: &WebSession,
    port: u16,
    host: &str,
) -> Result<tungstenite::WebSocket<Stream>> {
    let url = session.relay_url(port, host);
    let stream = connect(&session.origin, session.timeout)?;
    let req = tungstenite::client::IntoClientRequest::into_client_request(url.as_str())
        .context("building the relay request")?;
    let mut req = req;
    let h = req.headers_mut();
    h.insert(
        "Cookie",
        session
            .cookie_header()
            .parse()
            .map_err(|_| anyhow!("cookie is not a valid header"))?,
    );
    h.insert(
        "Origin",
        session
            .origin
            .http_url()
            .parse()
            .map_err(|_| anyhow!("origin is not a valid header"))?,
    );
    match tungstenite::client::client(req, stream) {
        Ok((ws, _resp)) => Ok(ws),
        Err(tungstenite::HandshakeError::Failure(tungstenite::Error::Http(resp))) => {
            let status = resp.status().as_u16();
            let why = match status {
                401 => "no valid web session (cookie refused)",
                403 => "port not allowed or cross-site refused",
                _ => "refused",
            };
            bail!("relay {url}: HTTP {status}, {why}")
        }
        Err(e) => Err(anyhow!("relay {url}: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn origins() {
        let o = Origin::parse("https://play.openvanilla.app").unwrap();
        assert_eq!(
            o,
            Origin {
                tls: true,
                host: "play.openvanilla.app".into(),
                port: 443,
                base: String::new()
            }
        );
        assert_eq!(
            o.ws_url("/ws/3724?host=x"),
            "wss://play.openvanilla.app/ws/3724?host=x"
        );
        assert_eq!(o.http_url(), "https://play.openvanilla.app");
        let o = Origin::parse("https://staging.openvanilla.app/login").unwrap();
        assert_eq!(o.base, "");
        let o = Origin::parse("http://127.0.0.1:8090/").unwrap();
        assert_eq!(
            (o.tls, o.port, o.authority()),
            (false, 8090, "127.0.0.1:8090".to_string())
        );
        assert_eq!(o.ws_url("/ws/8085"), "ws://127.0.0.1:8090/ws/8085");
        let o = Origin::parse("staging.openvanilla.app").unwrap();
        assert!(o.tls);
        assert!(Origin::parse("ftp://x").is_err());
        assert!(Origin::parse("https://").is_err());
    }

    #[test]
    fn http_response_plain_and_chunked() {
        let raw = b"HTTP/1.1 303 See Other\r\nLocation: /\r\nSet-Cookie: wr_session=abc123; HttpOnly; Secure; SameSite=Lax; Path=/\r\nSet-Cookie: other=1\r\ncontent-length: 0\r\n\r\n";
        let r = parse_response(raw).unwrap();
        assert_eq!(r.status, 303);
        assert_eq!(r.header("location"), Some("/"));
        assert_eq!(cookie_from(&r, SESSION_COOKIE).as_deref(), Some("abc123"));
        assert_eq!(cookie_from(&r, "missing"), None);

        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n7\r\n{\"user\"\r\n1d\r\n:\"OW1\",\"pass\":\"p\",\"host\":\"h\",\r\nb\r\n\"realm\":\"R\"\r\n1\r\n}\r\n0\r\n\r\n";
        let r = parse_response(raw).unwrap();
        let c: PlayCredential = serde_json::from_slice(&r.body).unwrap();
        assert_eq!(
            c,
            PlayCredential {
                user: "OW1".into(),
                pass: "p".into(),
                host: "h".into(),
                realm: "R".into(),
                character: None
            }
        );
    }

    #[test]
    fn a_cleared_cookie_is_no_cookie() {
        let raw =
            b"HTTP/1.1 200 OK\r\nSet-Cookie: wr_session=; Max-Age=0\r\nContent-Length: 2\r\n\r\nhi";
        let r = parse_response(raw).unwrap();
        assert_eq!(cookie_from(&r, SESSION_COOKIE), None);
        assert_eq!(r.text(), "hi");
    }

    #[test]
    fn play_credential_with_preset_char() {
        let c: PlayCredential = serde_json::from_str(
            r#"{"user":"OW_17","pass":"s3cret","host":"play.openvanilla.app","realm":"Open Vanilla","char":"Herald","dev_query_creds":"1"}"#,
        )
        .unwrap();
        assert_eq!(c.character.as_deref(), Some("Herald"));
        assert_eq!(c.realm, "Open Vanilla");
    }

    #[test]
    fn form_encoding() {
        assert_eq!(form_encode("a b&c=d/é"), "a+b%26c%3Dd%2F%C3%A9");
        assert_eq!(form_encode("Herald_1-x.y~"), "Herald_1-x.y~");
    }

    #[test]
    fn relay_url_matches_the_browser_client() {
        let s = WebSession {
            origin: Origin::parse("https://play.openvanilla.app").unwrap(),
            cookie: "t".into(),
            timeout: Duration::from_secs(1),
        };
        assert_eq!(
            s.relay_url(8085, "play.openvanilla.app"),
            "wss://play.openvanilla.app/ws/8085?host=play.openvanilla.app"
        );
        assert_eq!(s.cookie_header(), "wr_session=t");
    }

    #[test]
    fn pem_decoding() {
        // "hello" in base64 inside a fake PEM block.
        let pem = b"-----BEGIN CERTIFICATE-----\naGVs\nbG8=\n-----END CERTIFICATE-----\n";
        assert_eq!(pem_certs(pem), vec![b"hello".to_vec()]);
    }
}
