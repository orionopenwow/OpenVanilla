//! Live Link: Forge and a running Play Solo realm, while you play.
//!
//! * **Status**: is Play Solo set up, are its servers up (its SOAP console answers on localhost).
//! * **Make me a GM**: Play Solo's own account (SOLO) gets GM level 3 until the servers next start
//!   (Play Solo puts it back to a player then), so `.gps` and the Forge Link addon work.
//! * **Bring me here**: a `forgelink` teleport spot written to the realm's database, reloaded, and
//!   the character sent there (`tele name`).
//! * **Apply now**: the pack's Test & Play SQL run against the running realm, and every table the
//!   server can reload reloaded; what needs a restart is said.
//! * **From the game**: what `/forge` (the Forge Link addon) last marked: where you stood, what you
//!   targeted. The game writes it on /reload or logout; Forge reads `WTF\Account\*\SavedVariables`.
//!
//! Only ever 127.0.0.1, with Play Solo's own credentials from its `state.json`.

use crate::play::solo_dir;
use crate::project::Project;
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const ADMIN: &str = "SOLOADMIN";
pub const ACCOUNT: &str = "SOLO";
pub const TELE_NAME: &str = "forgelink";
const TELE_ID: u32 = 16_777_000;

/// The Forge Link addon, installed into the client by Test & Play.
pub const ADDON: &[(&str, &str)] = &[("ForgeLink.toc", include_str!("../forgelink/ForgeLink.toc")), ("ForgeLink.lua", include_str!("../forgelink/ForgeLink.lua"))];

#[derive(Debug, Clone)]
pub struct Solo {
    pub root: PathBuf,
    pub soap_port: u16,
    pub soap_password: String,
    pub db_port: u16,
    pub db_root_password: String,
}

/// Forge's test realm (its copy of Play Solo): ports and passwords (its state.json). Live Link
/// only ever talks to the test realm, never to the creator's own Play Solo.
pub fn solo(ov: &Path) -> Result<Solo> {
    let s = solo_at(crate::testbed::solo_dir()).context("Forge's test realm isn't made yet: press Test in game (or Install on the Test screen) once")?;
    // the test realm and your own Play Solo share ports: never send anything to your own
    if real_solo_running(ov) {
        bail!("your own Play Solo is running, not Forge's test realm: close it, then use Test in game");
    }
    Ok(s)
}

/// Whether the creator's own Play Solo is running (its run record is there and it answers).
pub fn real_solo_running(ov: &Path) -> bool {
    let root = solo_dir(ov);
    root.join("run.json").is_file() && solo_at(root).map(|s| port_open(s.db_port) || port_open(s.soap_port)).unwrap_or(false)
}

fn solo_at(root: PathBuf) -> Result<Solo> {
    let st: Value = serde_json::from_slice(&std::fs::read(root.join("state.json")).context("Play Solo isn't set up yet: start it once from the launcher")?)?;
    let port = |k: &str, d: u16| st["ports"][k].as_u64().map(|v| v as u16).unwrap_or(d);
    let pw = |k: &str| st[k].as_str().map(str::to_string).with_context(|| format!("Play Solo's state has no {k}"));
    Ok(Solo { soap_port: port("soap", 7879), db_port: port("db", 3311), soap_password: pw("soap_password")?, db_root_password: pw("db_root_password")?, root })
}

fn port_open(port: u16) -> bool {
    TcpStream::connect_timeout(&SocketAddr::from(([127, 0, 0, 1], port)), Duration::from_millis(400)).is_ok()
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}
fn xml_unescape(s: &str) -> String {
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&#xD;", "").replace("&amp;", "&")
}

impl Solo {
    /// One console command through mangosd's SOAP port; its text reply.
    pub fn soap(&self, command: &str) -> Result<String> {
        use base64::Engine;
        let body = format!(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:ns1=\"urn:MaNGOS\"><SOAP-ENV:Body><ns1:executeCommand><command>{}</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>",
            xml_escape(command)
        );
        let auth = base64::engine::general_purpose::STANDARD.encode(format!("{ADMIN}:{}", self.soap_password));
        let mut s = TcpStream::connect_timeout(&SocketAddr::from(([127, 0, 0, 1], self.soap_port)), Duration::from_secs(2)).context("Play Solo's world server isn't running (start Play Solo first)")?;
        s.set_read_timeout(Some(Duration::from_secs(15)))?;
        write!(s, "POST / HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Type: text/xml; charset=utf-8\r\nAuthorization: Basic {auth}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", self.soap_port, body.len())?;
        let mut reply = String::new();
        s.read_to_string(&mut reply).ok();
        if let (Some(a), Some(b)) = (reply.find("<result>"), reply.find("</result>")) {
            return Ok(xml_unescape(&reply[a + 8..b]).trim().to_string());
        }
        if let (Some(a), Some(b)) = (reply.find("<faultstring>"), reply.find("</faultstring>")) {
            bail!("the server said: {}", xml_unescape(&reply[a + 13..b]).trim());
        }
        bail!("the world server didn't take the command")
    }

    /// The MariaDB client Play Solo ships.
    fn client(&self) -> Result<PathBuf> {
        let bin = self.root.join("mariadb").join("bin");
        for n in ["mariadb.exe", "mysql.exe", "mariadb", "mysql"] {
            if bin.join(n).is_file() {
                return Ok(bin.join(n));
            }
        }
        if let Ok(c) = std::env::var("FORGE_MYSQL") {
            return Ok(PathBuf::from(c));
        }
        bail!("Play Solo's database client isn't in {}", bin.display())
    }

    /// SQL against the realm's world database (classicmangos).
    pub fn sql(&self, sql: &str) -> Result<String> {
        let mut cmd = std::process::Command::new(self.client()?);
        cmd.args(["--no-defaults", "--protocol=TCP", "--host=127.0.0.1", &format!("--port={}", self.db_port), "--user=root", "--batch", "--skip-column-names", "--default-character-set=utf8mb4", "classicmangos"])
            .env("MYSQL_PWD", &self.db_root_password)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // no console window
        }
        let mut child = cmd.spawn().context("can't start the database client")?;
        child.stdin.take().unwrap().write_all(sql.as_bytes())?;
        let out = child.wait_with_output()?;
        if !out.status.success() {
            bail!("the database refused it: {}", String::from_utf8_lossy(&out.stderr).trim().chars().rev().take(400).collect::<String>().chars().rev().collect::<String>());
        }
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    }
}

/// Play Solo's state for the Test screen.
pub fn status(ov: Option<&Path>) -> Value {
    let Some(ov) = ov else { return json!({"setup": false, "why": "Forge doesn't know your Open Vanilla folder yet"}) };
    if real_solo_running(ov) {
        return json!({"setup": true, "running": false, "own": true, "why": "your own Play Solo is running (Forge tests in its own copy): close it first"});
    }
    match solo_at(crate::testbed::solo_dir()) {
        Ok(s) => json!({"setup": true, "running": port_open(s.soap_port), "db": port_open(s.db_port)}),
        // not made yet: the first install makes it from Play Solo
        Err(_) if solo_dir(ov).join("state.json").is_file() => json!({"setup": true, "running": false, "fresh": true}),
        Err(_) => json!({"setup": false, "why": "Play Solo isn't set up yet: start it once from the launcher (Forge's test realm is copied from it)"}),
    }
}

/// SOLO becomes a GM until Play Solo next starts its servers.
pub fn make_gm(ov: &Path) -> Result<String> {
    let s = solo(ov)?;
    s.soap(&format!("account set gmlevel {ACCOUNT} 3"))
}

/// Send `character` to (map, x, y, z, o).
pub fn bring_me(ov: &Path, character: &str, map: u32, x: f64, y: f64, z: f64, o: f64) -> Result<String> {
    let name: String = character.chars().filter(|c| c.is_alphabetic()).collect();
    if name.is_empty() || name.len() > 12 {
        bail!("type your character's name (as it is in the game)");
    }
    let s = solo(ov)?;
    s.sql(&format!(
        "DELETE FROM game_tele WHERE name = '{TELE_NAME}' OR id = {TELE_ID};\nINSERT INTO game_tele (id, position_x, position_y, position_z, orientation, map, name) VALUES ({TELE_ID}, {x:.3}, {y:.3}, {z:.3}, {o:.3}, {map}, '{TELE_NAME}');\n"
    ))?;
    s.soap("reload game_tele")?;
    let r = s.soap(&format!("tele name {name} {TELE_NAME}"))?;
    // an offline character is moved in the database: it signs in there (CMaNGOS says "(offline)")
    let low = r.to_ascii_lowercase();
    if low.contains("not found") || low.contains("no player") || low.contains("does not exist") {
        bail!("the server said: {r}");
    }
    Ok(r)
}

/// Tables the world server reloads without a restart (its `reload` commands).
pub const RELOADABLE: &[&str] = &[
    "creature_ai_scripts", "creature_loot_template", "creature_questrelation", "creature_involvedrelation", "gameobject_loot_template", "gossip_menu", "gossip_menu_option",
    "item_loot_template", "npc_text", "npc_trainer", "npc_vendor", "pickpocketing_loot_template", "quest_template", "reference_loot_template", "skinning_loot_template",
    "areatrigger_teleport", "game_tele",
];

/// Run the pack's SQL on the running realm now, and reload what can be. Returns what was
/// reloaded and what waits for a restart.
pub fn apply_now(p: &Project, ov: &Path) -> Result<Value> {
    let s = solo(ov)?;
    let dev = s.root.join("forge-dev");
    let pack = &p.manifest.pack.id;
    let file = dev.join(format!("forge_dev_{}.sql", pack.replace('-', "_")));
    let sql = std::fs::read_to_string(&file).context("Install the pack for testing first (Test & Play)")?;
    s.sql(&sql)?;
    let d = crate::data::load(p);
    let tables: Vec<&String> = d.world.iter().filter(|(_, r)| !r.rows.is_empty()).map(|(t, _)| t).collect();
    let mut reloaded = vec![];
    let mut restart = vec![];
    for t in &tables {
        if RELOADABLE.contains(&t.as_str()) {
            match s.soap(&format!("reload {t}")) {
                Ok(_) => reloaded.push(t.to_string()),
                Err(_) => restart.push(t.to_string()),
            }
        } else if t.as_str() == "custom_texts" {
            // lines are read with the EventAI scripts
            if s.soap("reload all_eventai").is_ok() {
                reloaded.push("custom_texts".into());
            } else {
                restart.push("custom_texts".into());
            }
        } else {
            restart.push(t.to_string());
        }
    }
    if d.dbc.values().any(|r| !r.rows.is_empty()) {
        restart.push("client tables (DBC)".into());
    }
    Ok(json!({"reloaded": reloaded, "restart": restart}))
}

/// What `/forge` last marked in the game: the newest ForgeLink.lua under WTF\Account.
pub fn last_mark(game: &Path) -> Option<Value> {
    let acc = game.join("WTF").join("Account");
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    for a in std::fs::read_dir(&acc).ok()?.flatten() {
        let f = a.path().join("SavedVariables").join("ForgeLink.lua");
        if let Ok(m) = std::fs::metadata(&f).and_then(|m| m.modified()) {
            if best.as_ref().is_none_or(|b| m > b.0) {
                best = Some((m, f));
            }
        }
    }
    let text = std::fs::read_to_string(best?.1).ok()?;
    parse_mark(&text)
}

/// The `mark` table out of a saved-variables file (`["key"] = value,` lines).
pub fn parse_mark(text: &str) -> Option<Value> {
    let start = text.find("[\"mark\"]")?;
    let body = &text[start..];
    let end = body.find('}').unwrap_or(body.len());
    let mut out = serde_json::Map::new();
    for line in body[..end].lines() {
        let line = line.trim().trim_end_matches(',');
        let Some((k, v)) = line.split_once("] =") else { continue };
        let k = k.trim().trim_start_matches("[\"").trim_end_matches('"');
        let v = v.trim();
        let val = if let Some(s) = v.strip_prefix('"').and_then(|s| s.strip_suffix('"')) {
            json!(s.replace("\\\"", "\""))
        } else if let Ok(n) = v.parse::<f64>() {
            json!(n)
        } else {
            continue;
        };
        out.insert(k.to_string(), val);
    }
    out.get("x")?;
    Some(Value::Object(out))
}

/// Put the Forge Link addon into the client (it's removed with the pack).
pub fn install_addon(addons_dir: &Path) -> Result<PathBuf> {
    let dir = addons_dir.join("ForgeLink");
    std::fs::create_dir_all(&dir)?;
    for (name, text) in ADDON {
        std::fs::write(dir.join(name), text.replace('\n', "\r\n"))?;
    }
    std::fs::write(dir.join(".forge-dev"), "installed by Vanilla Forge's Test & Play\r\n")?;
    Ok(dir)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    /// A fake mangosd SOAP port: answers each request with `reply`, keeps what it was sent.
    fn fake_soap(reply: &'static str) -> (u16, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let got = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
        let g2 = got.clone();
        std::thread::spawn(move || {
            for s in l.incoming() {
                let mut s = s.unwrap();
                let mut buf = vec![0u8; 8192];
                let n = s.read(&mut buf).unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                g2.lock().unwrap().push(req);
                let body = format!("<SOAP-ENV:Envelope><SOAP-ENV:Body><ns1:executeCommandResponse><result>{reply}</result></ns1:executeCommandResponse></SOAP-ENV:Body></SOAP-ENV:Envelope>");
                let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}", body.len());
            }
        });
        (port, got)
    }

    fn fake_solo(dir: &Path, soap: u16) -> PathBuf {
        let ov = dir.join("ov");
        let solo = ov.join("solo");
        std::fs::create_dir_all(solo.join("bin")).unwrap();
        std::fs::write(ov.join("play_local.py"), "").unwrap();
        std::fs::write(solo.join("state.json"), format!("{{\"soap_password\": \"abc\", \"db_root_password\": \"def\", \"ports\": {{\"soap\": {soap}, \"db\": 1}}}}")).unwrap();
        // Live Link talks to Forge's test realm: here, the same folder
        crate::testbed::override_dirs(None, Some(solo));
        ov
    }

    #[test]
    fn soap_sends_the_command_with_the_admin_login() {
        let dir = tempfile::tempdir().unwrap();
        let (port, got) = fake_soap("Account SOLO gmlevel 3 &amp; done");
        let ov = fake_solo(dir.path(), port);
        let r = make_gm(&ov).unwrap();
        assert_eq!(r, "Account SOLO gmlevel 3 & done");
        let req = got.lock().unwrap()[0].clone();
        assert!(req.contains("<command>account set gmlevel SOLO 3</command>"), "{req}");
        use base64::Engine;
        assert!(req.contains(&format!("Basic {}", base64::engine::general_purpose::STANDARD.encode("SOLOADMIN:abc"))));
        assert_eq!(status(Some(&ov))["running"], true);
        // the creator's own Play Solo running (here its folder is the test one too, but its record
        // says it's the real one at work): Forge sends it nothing
        let test = dir.path().join("test-solo");
        std::fs::create_dir_all(&test).unwrap();
        std::fs::copy(ov.join("solo/state.json"), test.join("state.json")).unwrap();
        crate::testbed::override_dirs(None, Some(test));
        std::fs::write(ov.join("solo/run.json"), "{}").unwrap();
        assert!(make_gm(&ov).unwrap_err().to_string().contains("your own Play Solo"));
        assert_eq!(status(Some(&ov))["own"], true);
    }

    #[test]
    fn reads_what_forge_link_marked() {
        let text = "\r\nForgeLinkDB = {\r\n\t[\"mark\"] = {\r\n\t\t[\"char\"] = \"Aldric\",\r\n\t\t[\"x\"] = -8913.23,\r\n\t\t[\"y\"] = 554.633,\r\n\t\t[\"z\"] = 93.79,\r\n\t\t[\"map\"] = 0,\r\n\t\t[\"entry\"] = 1426002,\r\n\t\t[\"target\"] = \"Ember Whelp\",\r\n\t},\r\n}\r\n";
        let m = parse_mark(text).unwrap();
        assert_eq!(m["char"], "Aldric");
        assert_eq!(m["x"], -8913.23);
        assert_eq!(m["entry"], 1426002.0);
        assert!(parse_mark("ForgeLinkDB = {}").is_none());
        let dir = tempfile::tempdir().unwrap();
        let sv = dir.path().join("WTF/Account/SOLO/SavedVariables");
        std::fs::create_dir_all(&sv).unwrap();
        std::fs::write(sv.join("ForgeLink.lua"), text).unwrap();
        assert_eq!(last_mark(dir.path()).unwrap()["target"], "Ember Whelp");
    }

    #[test]
    fn the_addon_is_lua_50_and_installs() {
        let dir = tempfile::tempdir().unwrap();
        let d = install_addon(dir.path()).unwrap();
        assert!(d.join("ForgeLink.toc").is_file() && d.join(".forge-dev").is_file());
        let lint = crate::sim::lint("ForgeLink.lua", ADDON[1].1).unwrap();
        assert!(lint.is_empty(), "{lint:?}");
        assert!(ADDON[0].1.contains("## Interface: 11200"));
    }
}
