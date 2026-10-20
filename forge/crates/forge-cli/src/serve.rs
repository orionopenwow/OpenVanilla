//! `forge serve`: the app's UI in a browser, for development and for machines without the
//! desktop shell. Same UI files and the same command API (forge_core::api) as the desktop app;
//! it listens on 127.0.0.1 only.

use anyhow::Result;
use forge_core::api::{self, State};
use serde_json::{json, Value};
use tiny_http::{Header, Method, Response, Server};

const UI: &[(&str, &str, &str)] = &[
    ("/", include_str!("../../../app/ui/index.html"), "text/html; charset=utf-8"),
    ("/app.js", include_str!("../../../app/ui/app.js"), "text/javascript; charset=utf-8"),
    ("/style.css", include_str!("../../../app/ui/style.css"), "text/css; charset=utf-8"),
    ("/viewer.js", include_str!("../../../app/ui/viewer.js"), "text/javascript; charset=utf-8"),
    ("/terrain3d.js", include_str!("../../../app/ui/terrain3d.js"), "text/javascript; charset=utf-8"),
    ("/vendor/three.module.min.js", include_str!("../../../app/ui/vendor/three.module.min.js"), "text/javascript; charset=utf-8"),
    ("/vendor/OrbitControls.js", include_str!("../../../app/ui/vendor/OrbitControls.js"), "text/javascript; charset=utf-8"),
    ("/vendor/TransformControls.js", include_str!("../../../app/ui/vendor/TransformControls.js"), "text/javascript; charset=utf-8"),
];

pub fn serve(port: u16) -> Result<()> {
    let server = Server::http(("127.0.0.1", port)).map_err(|e| anyhow::anyhow!("{e}"))?;
    println!("Forge is at http://127.0.0.1:{port}/  (Ctrl+C to stop)");
    let mut st = State::load();
    for mut req in server.incoming_requests() {
        let url = req.url().split('?').next().unwrap_or("/").to_string();
        if req.method() == &Method::Post && url.starts_with("/api/") {
            let mut body = String::new();
            let _ = req.as_reader().read_to_string(&mut body);
            let args: Value = serde_json::from_str(&body).unwrap_or(json!({}));
            let out = match api::call(&mut st, &url[5..], &args) {
                Ok(data) => json!({"ok": true, "data": data}),
                Err(e) => json!({"ok": false, "error": format!("{e:#}")}),
            };
            let _ = req.respond(Response::from_string(out.to_string()).with_header(header("application/json")));
            continue;
        }
        match UI.iter().find(|(p, _, _)| *p == url) {
            Some((_, body, ct)) => {
                let _ = req.respond(Response::from_string(*body).with_header(header(ct)));
            }
            None => {
                let _ = req.respond(Response::from_string("not found").with_status_code(404));
            }
        }
    }
    Ok(())
}

fn header(ct: &str) -> Header {
    Header::from_bytes("Content-Type", ct).unwrap()
}
