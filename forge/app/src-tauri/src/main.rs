//! Vanilla Forge, the desktop app: a Tauri window around app/ui, with one command, `forge`,
//! that passes (command, args) to forge_core::api (the same API `forge serve` exposes). A few
//! commands only make sense on the desktop and are answered here: folder and file pickers, and
//! opening Open Vanilla's own pages in the browser.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use forge_core::api::{self, State};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tauri::Manager;

struct Shared(Arc<Mutex<State>>);

/// Only Open Vanilla's own sites open from the app (the links it shows: guide, Discord).
const OPENABLE: &[&str] = &["https://openvanilla.app/", "https://openvanilla.app/", "https://www.openvanilla.app/", "https://discord.gg/", "https://github.com/orionopenwow/"];

fn desktop(cmd: &str, args: &Value) -> Option<Result<Value, String>> {
    let s = |k: &str| args.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    Some(match cmd {
        "pick_folder" => {
            let mut d = rfd::FileDialog::new().set_title(s("title"));
            if !s("start").is_empty() {
                d = d.set_directory(s("start"));
            }
            Ok(json!(d.pick_folder().map(|p| p.display().to_string())))
        }
        "pick_file" => {
            let mut d = rfd::FileDialog::new().set_title(s("title"));
            let exts: Vec<String> = args.get("extensions").and_then(Value::as_array).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
            if !exts.is_empty() {
                d = d.add_filter(s("filter"), &exts);
            }
            Ok(json!(d.pick_file().map(|p| p.display().to_string())))
        }
        "open_url" => {
            let url = s("url");
            if !OPENABLE.iter().any(|p| url.starts_with(p)) {
                return Some(Err("Forge only opens Open Vanilla's own pages".into()));
            }
            open::that_detached(&url).map(|_| json!(true)).map_err(|e| e.to_string())
        }
        _ => return None,
    })
}

/// Every UI call. Runs off the UI thread (builds and game indexing can take a moment).
#[tauri::command]
async fn forge(shared: tauri::State<'_, Shared>, cmd: String, args: Value) -> Result<Value, String> {
    let st = shared.0.clone();
    tauri::async_runtime::spawn_blocking(move || {
        if let Some(r) = desktop(&cmd, &args) {
            return r;
        }
        let mut st = st.lock().map_err(|_| "Forge's state is unavailable".to_string())?;
        api::call(&mut st, &cmd, &args).map_err(|e| format!("{e:#}"))
    })
    .await
    .map_err(|e| e.to_string())?
}

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            // the installer's own Python (python\python.exe beside Forge) runs the Model Porter
            if let Ok(dir) = app.path().resource_dir() {
                let py = dir.join("python").join(if cfg!(windows) { "python.exe" } else { "bin/python3" });
                if py.is_file() {
                    std::env::set_var("FORGE_BUNDLED_PYTHON", py);
                }
                // the command-line forge (also the MCP server for the creator's own AI)
                let cli = dir.join(if cfg!(windows) { "forge.exe" } else { "forge" });
                if cli.is_file() {
                    std::env::set_var("FORGE_CLI", cli);
                }
            }
            Ok(())
        })
        .manage(Shared(Arc::new(Mutex::new(State::load()))))
        .invoke_handler(tauri::generate_handler![forge])
        .run(tauri::generate_context!())
        .expect("Vanilla Forge failed to start");
}
