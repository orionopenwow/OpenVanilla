//! A loopback port that pipes bytes to the real upstream: a TCP socket (direct mode) or the realm
//! service's `/ws/{port}` WebSocket relay (web mode).
//!
//! benilla-protocol's native transport dials a `host:port` over TCP. Pointing it at this bridge
//! lets the unmodified protocol code (SRP6 logon, world handshake, header crypto, codecs) run over
//! either upstream, byte for byte. The bridge adds nothing to the stream; it also gives us a clean
//! way to close a session (the protocol crate's split socket halves cannot be shut down from
//! outside) and byte counters for the report.
//!
//! Each accepted local connection dials its own upstream, because realmd logon may redial (the
//! crate retries an ambiguous SRP `B` with a fresh connection).

use std::io::{self, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use anyhow::{anyhow, Result};

use crate::web::{self, Stream, WebSession};

/// Where the bridge sends its bytes.
#[derive(Clone)]
pub enum Upstream {
    /// A plain TCP `host:port`.
    Tcp { host: String, port: u16 },
    /// The relay of a logged-in web session; `host` is only the `?host=` label.
    Ws {
        session: WebSession,
        port: u16,
        host: String,
    },
}

impl Upstream {
    pub fn describe(&self) -> String {
        match self {
            Upstream::Tcp { host, port } => format!("tcp://{host}:{port}"),
            Upstream::Ws {
                session,
                port,
                host,
                ..
            } => session.relay_url(*port, host),
        }
    }
}

type Closer = Box<dyn Fn() + Send>;

struct Shared {
    upstream: Upstream,
    error: Mutex<Option<String>>,
    closers: Mutex<Vec<Closer>>,
    up: AtomicU64,
    down: AtomicU64,
    stop: AtomicBool,
    dial_timeout: Duration,
}

/// A running bridge. Dropping it closes every connection it carries.
pub struct Bridge {
    local: SocketAddr,
    shared: Arc<Shared>,
}

impl Bridge {
    pub fn start(upstream: Upstream, dial_timeout: Duration) -> Result<Bridge> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let local = listener.local_addr()?;
        let shared = Arc::new(Shared {
            upstream,
            error: Mutex::new(None),
            closers: Mutex::new(Vec::new()),
            up: AtomicU64::new(0),
            down: AtomicU64::new(0),
            stop: AtomicBool::new(false),
            dial_timeout,
        });
        let s = Arc::clone(&shared);
        thread::Builder::new()
            .name("hl-bridge-accept".into())
            .spawn(move || {
                for conn in listener.incoming() {
                    if s.stop.load(Ordering::SeqCst) {
                        break;
                    }
                    let Ok(local) = conn else { continue };
                    local.set_nodelay(true).ok();
                    let s2 = Arc::clone(&s);
                    thread::spawn(move || handle(s2, local));
                }
            })?;
        Ok(Bridge { local, shared })
    }

    /// The `127.0.0.1:port` to hand to benilla-protocol in place of the real address.
    pub fn addr(&self) -> String {
        self.local.to_string()
    }

    /// The last upstream failure (a refused dial, a relay that said 401, ...), if any.
    pub fn error(&self) -> Option<String> {
        self.shared.error.lock().unwrap().clone()
    }

    /// Bytes client→server and server→client so far.
    pub fn bytes(&self) -> (u64, u64) {
        (
            self.shared.up.load(Ordering::Relaxed),
            self.shared.down.load(Ordering::Relaxed),
        )
    }

    pub fn describe(&self) -> String {
        self.shared.upstream.describe()
    }

    /// Close every carried connection and stop accepting.
    pub fn close(&self) {
        if self.shared.stop.swap(true, Ordering::SeqCst) {
            return;
        }
        for c in self.shared.closers.lock().unwrap().drain(..) {
            c();
        }
        // Wake the accept loop so its thread ends.
        let _ = TcpStream::connect_timeout(&self.local, Duration::from_millis(200));
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        self.close();
    }
}

fn record(s: &Shared, e: String) {
    let mut slot = s.error.lock().unwrap();
    if slot.is_none() {
        *slot = Some(e);
    }
}

fn handle(s: Arc<Shared>, local: TcpStream) {
    match s.upstream.clone() {
        Upstream::Tcp { host, port } => match dial_tcp(&host, port, s.dial_timeout) {
            Ok(up) => pipe_tcp(s, local, up),
            Err(e) => {
                record(&s, format!("{e:#}"));
                let _ = local.shutdown(Shutdown::Both);
            }
        },
        Upstream::Ws {
            session,
            port,
            host,
        } => match web::open_relay(&session, port, &host) {
            Ok(ws) => pipe_ws(s, local, ws),
            Err(e) => {
                record(&s, format!("{e:#}"));
                let _ = local.shutdown(Shutdown::Both);
            }
        },
    }
}

fn dial_tcp(host: &str, port: u16, timeout: Duration) -> Result<TcpStream> {
    let addrs: Vec<SocketAddr> = (host, port)
        .to_socket_addrs()
        .map_err(|e| anyhow!("cannot find a server called {host}:{port} ({e})"))?
        .collect();
    if addrs.is_empty() {
        return Err(anyhow!("cannot find a server called {host}:{port}"));
    }
    let mut last = None;
    for a in addrs {
        match TcpStream::connect_timeout(&a, timeout) {
            Ok(s) => {
                s.set_nodelay(true).ok();
                return Ok(s);
            }
            Err(e) => last = Some(e),
        }
    }
    Err(anyhow!(
        "nothing answered at {host}:{port} ({})",
        last.map(|e| e.to_string()).unwrap_or_default()
    ))
}

fn copy_counting(mut from: TcpStream, mut to: TcpStream, counter: &AtomicU64) {
    let mut buf = [0u8; 16 * 1024];
    loop {
        match from.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if to.write_all(&buf[..n]).is_err() {
                    break;
                }
                counter.fetch_add(n as u64, Ordering::Relaxed);
            }
        }
    }
    let _ = to.shutdown(Shutdown::Write);
}

fn pipe_tcp(s: Arc<Shared>, local: TcpStream, up: TcpStream) {
    let (Ok(l2), Ok(u2), Ok(lc), Ok(uc)) = (
        local.try_clone(),
        up.try_clone(),
        local.try_clone(),
        up.try_clone(),
    ) else {
        record(&s, "could not clone sockets".into());
        return;
    };
    s.closers.lock().unwrap().push(Box::new(move || {
        let _ = lc.shutdown(Shutdown::Both);
        let _ = uc.shutdown(Shutdown::Both);
    }));
    if s.stop.load(Ordering::SeqCst) {
        let _ = local.shutdown(Shutdown::Both);
        let _ = up.shutdown(Shutdown::Both);
        return;
    }
    let s_up = Arc::clone(&s);
    let t = thread::spawn(move || copy_counting(local, up, &s_up.up));
    copy_counting(u2, l2, &s.down);
    let _ = t.join();
}

fn is_timeout(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
    )
}

fn pipe_ws(s: Arc<Shared>, local: TcpStream, ws: tungstenite::WebSocket<Stream>) {
    use tungstenite::{Error as WsError, Message};

    // The WebSocket cannot be split, so both pumps share it; the reader holds the lock only for
    // one bounded read (a short socket timeout), which keeps writes flowing.
    if let Err(e) = ws
        .get_ref()
        .tcp()
        .set_read_timeout(Some(Duration::from_millis(15)))
    {
        record(&s, format!("relay socket: {e}"));
        return;
    }
    let ws_tcp = ws.get_ref().tcp().try_clone();
    let ws = Arc::new(Mutex::new(ws));
    let (Ok(local_w), Ok(local_c), Ok(ws_c)) = (local.try_clone(), local.try_clone(), ws_tcp)
    else {
        record(&s, "could not clone sockets".into());
        return;
    };
    s.closers.lock().unwrap().push(Box::new(move || {
        let _ = local_c.shutdown(Shutdown::Both);
        let _ = ws_c.shutdown(Shutdown::Both);
    }));

    // local -> relay
    let ws_tx = Arc::clone(&ws);
    let s_up = Arc::clone(&s);
    let mut local_r = local;
    let up = thread::spawn(move || {
        let mut buf = [0u8; 16 * 1024];
        loop {
            match local_r.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let mut w = ws_tx.lock().unwrap();
                    if let Err(e) = w.send(Message::Binary(buf[..n].to_vec())) {
                        record(&s_up, format!("relay write: {e}"));
                        break;
                    }
                    s_up.up.fetch_add(n as u64, Ordering::Relaxed);
                }
            }
        }
        if let Ok(mut w) = ws_tx.lock() {
            let _ = w.close(None);
            let _ = w.flush();
        }
    });

    // relay -> local
    let mut local_w = local_w;
    loop {
        if s.stop.load(Ordering::SeqCst) {
            break;
        }
        let msg = {
            let mut r = ws.lock().unwrap();
            r.read()
        };
        match msg {
            Ok(Message::Binary(b)) => {
                if local_w.write_all(&b).is_err() {
                    break;
                }
                s.down.fetch_add(b.len() as u64, Ordering::Relaxed);
            }
            Ok(Message::Text(t)) => {
                if local_w.write_all(t.as_bytes()).is_err() {
                    break;
                }
                s.down.fetch_add(t.len() as u64, Ordering::Relaxed);
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(WsError::Io(e)) if is_timeout(&e) => {
                // Let the writer in before the next bounded read.
                thread::sleep(Duration::from_millis(1));
            }
            Err(WsError::ConnectionClosed) | Err(WsError::AlreadyClosed) => break,
            Err(e) => {
                if !s.stop.load(Ordering::SeqCst) {
                    record(&s, format!("relay read: {e}"));
                }
                break;
            }
        }
    }
    let _ = local_w.shutdown(Shutdown::Both);
    let _ = up.join();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tcp_bridge_pipes_both_ways_and_counts() {
        // An echo server upstream.
        let echo = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = echo.local_addr().unwrap().port();
        thread::spawn(move || {
            let (mut c, _) = echo.accept().unwrap();
            let mut buf = [0u8; 64];
            loop {
                match c.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => c.write_all(&buf[..n]).unwrap(),
                }
            }
        });
        let b = Bridge::start(
            Upstream::Tcp {
                host: "127.0.0.1".into(),
                port,
            },
            Duration::from_secs(2),
        )
        .unwrap();
        let mut c = TcpStream::connect(b.addr()).unwrap();
        c.write_all(b"hello").unwrap();
        let mut got = [0u8; 5];
        c.read_exact(&mut got).unwrap();
        assert_eq!(&got, b"hello");
        // counters are updated after the write
        thread::sleep(Duration::from_millis(50));
        assert_eq!(b.bytes(), (5, 5));
        b.close();
        let mut rest = Vec::new();
        c.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        assert_eq!(
            c.read_to_end(&mut rest).unwrap_or(0),
            0,
            "closed after close()"
        );
    }

    #[test]
    fn a_dead_upstream_is_reported() {
        // Bind then drop to get a port nobody listens on.
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let b = Bridge::start(
            Upstream::Tcp {
                host: "127.0.0.1".into(),
                port,
            },
            Duration::from_secs(1),
        )
        .unwrap();
        let mut c = TcpStream::connect(b.addr()).unwrap();
        let mut buf = [0u8; 1];
        c.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let _ = c.read(&mut buf);
        thread::sleep(Duration::from_millis(50));
        let err = b.error().expect("dial error recorded");
        assert!(err.contains("nothing answered"), "{err}");
    }
}
