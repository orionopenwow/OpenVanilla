//! End-to-end: fake agent + fake realmd/mangosd TCP servers + player WebSocket clients.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use openvanilla_relay::{serve, sha256_hex, Config, Limits};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;

const HOST: &str = "abcdefghijklmn23";
const PRIV: &str = "privatehost22222";
const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const INVITE: &str = "GOODCODE23";

/// TCP server that answers every chunk with `<tag>:` + chunk.
async fn fake_server(tag: &'static str) -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let (mut s, _) = l.accept().await.unwrap();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 65536];
                loop {
                    match s.read(&mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            let mut out = tag.as_bytes().to_vec();
                            out.push(b':');
                            out.extend_from_slice(&buf[..n]);
                            if s.write_all(&out).await.is_err() {
                                break;
                            }
                        }
                    }
                }
            });
        }
    });
    port
}

async fn start_relay(limits: Limits, dir: &std::path::Path) -> SocketAddr {
    let allow = dir.join("allow.txt");
    std::fs::write(
        &allow,
        format!("# test\n{HOST} {}\n{PRIV} {} private\n", sha256_hex(TOKEN), sha256_hex(TOKEN)),
    )
    .unwrap();
    let cfg = Config { allow_file: Some(allow), limits, ..Default::default() };
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(serve(l, cfg, std::future::pending()));
    addr
}

fn tmpdir(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("owrelay-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn agent_req(url: String, host: &str, token: &str) -> tokio_tungstenite::tungstenite::handshake::client::Request {
    let mut req = url.into_client_request().unwrap();
    req.headers_mut().insert("authorization", format!("Bearer {token}").parse().unwrap());
    req.headers_mut().insert("x-host-id", host.parse().unwrap());
    req
}

/// Fake openvanilla-node agent: dials local fake servers on `open`, answers invites.
async fn start_agent(relay: SocketAddr, host: &'static str, ports: HashMap<u16, u16>) {
    let (ws, _) = tokio_tungstenite::connect_async(agent_req(format!("ws://{relay}/agent"), host, TOKEN))
        .await
        .unwrap();
    let (mut tx, mut rx) = ws.split();
    let (out_tx, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    tokio::spawn(async move {
        while let Some(t) = out_rx.recv().await {
            if tx.send(Message::text(t)).await.is_err() {
                break;
            }
        }
    });
    tokio::spawn(async move {
        while let Some(Ok(Message::Text(t))) = rx.next().await {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            if let Some(code) = v.get("invite_check") {
                let id = v["stream"].as_u64().unwrap();
                let key = if code == INVITE { "invite_ok" } else { "invite_no" };
                out_tx.send(serde_json::json!({ key: id }).to_string()).unwrap();
            }
            if let Some(id) = v.get("open").and_then(|x| x.as_u64()) {
                let local = ports[&(v["port"].as_u64().unwrap() as u16)];
                let sealed = v.get("e2e").and_then(|x| x.as_u64()) == Some(1);
                tokio::spawn(async move {
                    let tcp = TcpStream::connect(("127.0.0.1", local)).await.unwrap();
                    let (ws, _) = tokio_tungstenite::connect_async(agent_req(
                        format!("ws://{relay}/agent/stream/{id}"),
                        host,
                        TOKEN,
                    ))
                    .await
                    .unwrap();
                    let (mut wtx, mut wrx) = ws.split();
                    if sealed {
                        // a real agent would run the e2e handshake here; the fake just marks the stream
                        wtx.send(Message::binary(b"e2e:".to_vec())).await.unwrap();
                    }
                    let (mut tr, mut tw) = tcp.into_split();
                    let a = async {
                        let mut buf = vec![0u8; 65536];
                        while let Ok(n) = tr.read(&mut buf).await {
                            if n == 0 || wtx.send(Message::binary(buf[..n].to_vec())).await.is_err() {
                                break;
                            }
                        }
                    };
                    let b = async {
                        while let Some(Ok(m)) = wrx.next().await {
                            match m {
                                Message::Binary(b) => {
                                    if tw.write_all(&b).await.is_err() {
                                        break;
                                    }
                                }
                                Message::Close(_) => break,
                                _ => {}
                            }
                        }
                    };
                    tokio::select! { _ = a => {}, _ = b => {} }
                });
            }
        }
    });
    // let the control session register
    tokio::time::sleep(Duration::from_millis(100)).await;
}

async fn setup(name: &str, limits: Limits) -> SocketAddr {
    let p1 = fake_server("realmd").await;
    let p2 = fake_server("mangosd").await;
    let relay = start_relay(limits, &tmpdir(name)).await;
    let ports: HashMap<u16, u16> = [(3724, p1), (8085, p2)].into();
    start_agent(relay, HOST, ports.clone()).await;
    start_agent(relay, PRIV, ports).await;
    relay
}

type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>;

async fn player(relay: SocketAddr, path: &str) -> Result<Ws, u16> {
    match tokio_tungstenite::connect_async(format!("ws://{relay}{path}")).await {
        Ok((ws, _)) => Ok(ws),
        Err(tokio_tungstenite::tungstenite::Error::Http(r)) => Err(r.status().as_u16()),
        Err(e) => panic!("{e}"),
    }
}

async fn roundtrip(ws: &mut Ws, data: &[u8]) -> Vec<u8> {
    ws.send(Message::binary(data.to_vec())).await.unwrap();
    let mut got = Vec::new();
    while let Some(Ok(m)) = tokio::time::timeout(Duration::from_secs(10), ws.next()).await.unwrap() {
        if let Message::Binary(b) = m {
            got.extend_from_slice(&b);
            if got.len() >= data.len() + 7 {
                break;
            }
        }
    }
    got
}

#[tokio::test]
async fn bytes_flow_both_ways_on_both_ports() {
    let relay = setup("flow", Limits::default()).await;
    let mut a = player(relay, &format!("/h/{HOST}/ws/3724")).await.unwrap();
    let mut b = player(relay, &format!("/h/{HOST}/ws/8085")).await.unwrap();
    assert_eq!(roundtrip(&mut a, b"\x00\x08hello").await, b"realmd:\x00\x08hello");
    assert_eq!(roundtrip(&mut b, b"world").await, b"mangosd:world");
    assert_eq!(roundtrip(&mut a, b"again").await, b"realmd:again");

    let body = reqwest::get(format!("http://{relay}/metrics")).await.unwrap().text().await.unwrap();
    assert!(body.contains("openvanilla_relay_streams 2"), "{body}");
    assert!(body.contains("openvanilla_relay_agents 2"), "{body}");
    assert!(body.contains("openvanilla_relay_bytes_total{dir=\"to_player\"}"));

    a.close(None).await.unwrap();
    // stream count drops after the player leaves
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let body = reqwest::get(format!("http://{relay}/metrics")).await.unwrap().text().await.unwrap();
        if body.contains("openvanilla_relay_streams 1\n") {
            break;
        }
        assert!(Instant::now() < deadline, "{body}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn bad_paths_and_offline_hosts() {
    let relay = setup("paths", Limits::default()).await;
    assert_eq!(player(relay, &format!("/h/{HOST}/ws/3306")).await.err(), Some(404));
    assert_eq!(player(relay, "/h/zzzzzzzzzzzzzzzz/ws/3724").await.err(), Some(404));
    assert_eq!(player(relay, "/h/NOT-AN-ID/ws/3724").await.err(), Some(404));
}

#[tokio::test]
async fn agent_auth_is_required() {
    let relay = setup("auth", Limits::default()).await;
    let bad = tokio_tungstenite::connect_async(agent_req(format!("ws://{relay}/agent"), HOST, "wrong")).await;
    match bad {
        Err(tokio_tungstenite::tungstenite::Error::Http(r)) => assert_eq!(r.status().as_u16(), 401),
        _ => panic!("expected 401"),
    }
    let unknown = tokio_tungstenite::connect_async(agent_req(
        format!("ws://{relay}/agent"),
        "unknownhost22222",
        TOKEN,
    ))
    .await;
    assert!(unknown.is_err());
    // stream endpoint with nothing pending
    let s = tokio_tungstenite::connect_async(agent_req(format!("ws://{relay}/agent/stream/999"), HOST, TOKEN)).await;
    match s {
        Err(tokio_tungstenite::tungstenite::Error::Http(r)) => assert_eq!(r.status().as_u16(), 404),
        _ => panic!("expected 404"),
    }
}

#[tokio::test]
async fn private_host_needs_valid_invite() {
    let relay = setup("invite", Limits::default()).await;
    assert_eq!(player(relay, &format!("/h/{PRIV}/ws/3724")).await.err(), Some(403));
    assert_eq!(player(relay, &format!("/h/{PRIV}/ws/3724?invite=BADCODE234")).await.err(), Some(403));
    assert_eq!(player(relay, &format!("/h/{PRIV}/ws/3724?invite=x")).await.err(), Some(403));
    let mut ok = player(relay, &format!("/h/{PRIV}/ws/8085?invite={INVITE}")).await.unwrap();
    assert_eq!(roundtrip(&mut ok, b"hi").await, b"mangosd:hi");
    // public host ignores invites
    assert!(player(relay, &format!("/h/{HOST}/ws/3724?invite=BADCODE234")).await.is_ok());
}

#[tokio::test]
async fn stream_limit() {
    let relay = setup("streams", Limits { max_streams: 2, ..Default::default() }).await;
    let _a = player(relay, &format!("/h/{HOST}/ws/3724")).await.unwrap();
    let _b = player(relay, &format!("/h/{HOST}/ws/8085")).await.unwrap();
    assert_eq!(player(relay, &format!("/h/{HOST}/ws/3724")).await.err(), Some(503));
    // other hosts are unaffected
    assert!(player(relay, &format!("/h/{PRIV}/ws/3724?invite={INVITE}")).await.is_ok());
}

#[tokio::test]
async fn bandwidth_is_rate_limited() {
    let relay = setup("rate", Limits { bytes_per_sec: 20_000, ..Default::default() }).await;
    let mut a = player(relay, &format!("/h/{HOST}/ws/3724")).await.unwrap();
    let t = Instant::now();
    // 3 x 20 KB up + echoes down = ~120 KB through a 20 KB/s bucket (20 KB burst)
    for _ in 0..3 {
        let data = vec![7u8; 20_000];
        let got = roundtrip(&mut a, &data).await;
        assert_eq!(got.len(), 20_007);
    }
    let el = t.elapsed();
    assert!(el >= Duration::from_secs(4), "too fast: {el:?}");
    assert!(el < Duration::from_secs(9), "too slow: {el:?}");
}

#[tokio::test]
async fn daily_quota() {
    let relay = setup("daily", Limits { daily_bytes: 1000, ..Default::default() }).await;
    let mut a = player(relay, &format!("/h/{HOST}/ws/3724")).await.unwrap();
    assert_eq!(roundtrip(&mut a, &[1u8; 600]).await.len(), 607);
    // the next frame crosses the cap: the stream is closed
    a.send(Message::binary(vec![2u8; 600])).await.unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(m) = a.next().await {
            match m {
                Ok(Message::Close(_)) | Err(_) => break,
                Ok(Message::Binary(b)) => panic!("frame over quota was relayed: {} bytes", b.len()),
                _ => {}
            }
        }
    })
    .await;
    assert!(ended.is_ok(), "stream not closed at quota");
    assert_eq!(player(relay, &format!("/h/{HOST}/ws/3724")).await.err(), Some(429));
    assert!(player(relay, &format!("/h/{PRIV}/ws/3724?invite={INVITE}")).await.is_ok());
}

#[tokio::test]
async fn idle_streams_are_closed() {
    let relay = setup("idle", Limits { stream_idle: Duration::from_millis(500), ..Default::default() }).await;
    let mut a = player(relay, &format!("/h/{HOST}/ws/3724")).await.unwrap();
    let t = Instant::now();
    let r = tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(m) = a.next().await {
            if matches!(m, Ok(Message::Close(_)) | Err(_)) { break; }
        }
    })
    .await;
    assert!(r.is_ok(), "idle stream not closed");
    assert!(t.elapsed() >= Duration::from_millis(400));
}

#[tokio::test]
async fn central_verify_endpoint() {
    use axum::{extract::Query, routing::get, Json, Router};
    // fake central: accepts HOST with TOKEN, private
    let central = Router::new().route(
        "/api/directory/verify",
        get(|h: axum::http::HeaderMap, Query(q): Query<HashMap<String, String>>| async move {
            let auth_ok = h.get("authorization").map(|v| v == "Bearer s3cret").unwrap_or(false);
            let ok = auth_ok && q["host_id"] == HOST && q["token_sha"] == sha256_hex(TOKEN);
            Json(serde_json::json!({"ok": ok, "visibility": "private"}))
        }),
    );
    let cl = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let caddr = cl.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(cl, central).await.unwrap() });

    let cfg = Config {
        verify_url: Some(format!("http://{caddr}/api/directory/verify")),
        verify_secret: Some("s3cret".into()),
        ..Default::default()
    };
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay = l.local_addr().unwrap();
    tokio::spawn(serve(l, cfg, std::future::pending()));
    let p = fake_server("realmd").await;
    start_agent(relay, HOST, [(3724, p), (8085, p)].into()).await;
    // private per central -> invite enforced
    assert_eq!(player(relay, &format!("/h/{HOST}/ws/3724")).await.err(), Some(403));
    let mut ok = player(relay, &format!("/h/{HOST}/ws/3724?invite={INVITE}")).await.unwrap();
    assert_eq!(roundtrip(&mut ok, b"x").await, b"realmd:x");
    let bad = tokio_tungstenite::connect_async(agent_req(format!("ws://{relay}/agent"), HOST, "nope")).await;
    assert!(bad.is_err());
}

#[tokio::test]
async fn graceful_shutdown_closes_sessions() {
    let p = fake_server("realmd").await;
    let dir = tmpdir("shutdown");
    let allow = dir.join("allow.txt");
    std::fs::write(&allow, format!("{HOST} {}\n", sha256_hex(TOKEN))).unwrap();
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay = l.local_addr().unwrap();
    let srv = tokio::spawn(serve(
        l,
        Config { allow_file: Some(allow), ..Default::default() },
        async { let _ = stop_rx.await; },
    ));
    start_agent(relay, HOST, [(3724, p), (8085, p)].into()).await;
    let mut a = player(relay, &format!("/h/{HOST}/ws/3724")).await.unwrap();
    assert_eq!(roundtrip(&mut a, b"x").await, b"realmd:x");
    stop_tx.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(5), srv).await.expect("server drained").unwrap().unwrap();
}

#[tokio::test]
async fn e2e_flag_reaches_the_agent() {
    let relay = setup("e2e", Limits::default()).await;
    let mut a = player(relay, &format!("/h/{HOST}/ws/8085?e2e=1")).await.unwrap();
    let got = roundtrip(&mut a, b"sealed").await;
    assert!(got.starts_with(b"e2e:"), "{:?}", String::from_utf8_lossy(&got));
    let mut b = player(relay, &format!("/h/{HOST}/ws/8085")).await.unwrap();
    assert_eq!(roundtrip(&mut b, b"plain").await, b"mangosd:plain");
}
