//! Runs scenarios against one or more clients and builds the JSON report.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use serde::Serialize;

use crate::client::{CharInfo, Check, Client, ClientConfig, Timings};
use crate::scenario::{expand_runtime, parse_cmd, parse_line, Cmd, ExpectKind, Scenario, Step};

/// Exit codes: everything passed / something failed / could not get in.
pub const EXIT_OK: i32 = 0;
pub const EXIT_FAIL: i32 = 1;
pub const EXIT_NO_ENTRY: i32 = 2;

#[derive(Debug, Clone, Serialize)]
pub struct StepReport {
    pub line: usize,
    pub client: String,
    pub step: String,
    pub ok: bool,
    /// A `try` that failed or a `when` whose variable was not set: not run, not a failure.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub skipped: bool,
    pub ms: u64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub detail: String,
}

/// A step's detail that marks it skipped (by `try` or `when`), not passed or failed.
pub const SKIP: &str = "skipped: ";

#[derive(Debug, Clone, Serialize)]
pub struct ScenarioReport {
    pub name: String,
    pub pass: usize,
    pub fail: usize,
    pub skipped: usize,
    pub ms: u64,
    pub steps: Vec<StepReport>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ClientReport {
    pub label: String,
    pub game_account: String,
    pub realm: Option<String>,
    pub characters: Vec<CharInfo>,
    pub timings: Timings,
    pub bytes_up: u64,
    pub bytes_down: u64,
    pub packets: u64,
    pub packets_skipped: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    pub tool: &'static str,
    pub version: &'static str,
    pub mode: String,
    pub target: String,
    pub ok: bool,
    pub exit: i32,
    pub pass: usize,
    pub fail: usize,
    pub failures: Vec<String>,
    pub characters: Vec<CharInfo>,
    pub ms: u64,
    pub clients: Vec<ClientReport>,
    pub scenarios: Vec<ScenarioReport>,
    /// Run-time variables at the end (`matches` named groups, `set`).
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub vars: BTreeMap<String, String>,
}

/// How to build the clients a scenario names.
pub struct RunConfig {
    /// Client `a`.
    pub primary: ClientConfig,
    /// Accounts for other clients, by label (`b` = `HL_USER2`/`HL_PASS2`).
    pub others: BTreeMap<String, (String, String, Option<String>)>,
    /// Default `within` for expectations and the cap on `find npc`.
    pub step_timeout: Duration,
    /// How long `logout` waits for `SMSG_LOGOUT_COMPLETE` (a non-resting logout takes 20 s).
    pub logout_timeout: Duration,
    pub mode_name: String,
    pub target: String,
}

pub struct Runner {
    cfg: RunConfig,
    clients: BTreeMap<String, Client>,
    /// Client reports kept after a client is dropped (logout), keyed by label.
    seen: BTreeMap<String, ClientReport>,
    no_entry: bool,
    /// Run-time variables: `matches` named groups and `set`, for `%{var}`, `check` and `when`.
    vars: BTreeMap<String, String>,
}

impl Runner {
    pub fn new(cfg: RunConfig) -> Runner {
        Runner {
            cfg,
            clients: BTreeMap::new(),
            seen: BTreeMap::new(),
            no_entry: false,
            vars: BTreeMap::new(),
        }
    }

    fn client_config(&self, label: &str) -> Result<ClientConfig> {
        if label == "a" {
            return Ok(self.cfg.primary.clone());
        }
        let (user, pass, character) = self.cfg.others.get(label).cloned().ok_or_else(|| {
            anyhow!(
                "client [{label}] has no account: set HL_USER_{0}/HL_PASS_{0}{1}",
                label.to_ascii_uppercase(),
                if label == "b" {
                    " (or HL_USER2/HL_PASS2)"
                } else {
                    ""
                }
            )
        })?;
        Ok(ClientConfig {
            label: label.to_string(),
            user,
            pass,
            character,
            fallback_character: None,
            ..self.cfg.primary.clone()
        })
    }

    fn snapshot(&mut self, label: &str) {
        if let Some(c) = self.clients.get(label) {
            let (up, down) = c.bytes();
            let prev = self.seen.get(label);
            let r = ClientReport {
                label: label.to_string(),
                game_account: c.game_account.clone(),
                realm: c.realm.clone(),
                characters: c.characters.iter().map(CharInfo::from).collect(),
                timings: c.timings.clone(),
                bytes_up: up + prev.map_or(0, |p| p.bytes_up),
                bytes_down: down + prev.map_or(0, |p| p.bytes_down),
                packets: c.model.packets,
                packets_skipped: c.model.skipped,
            };
            self.seen.insert(label.to_string(), r);
        }
    }

    /// Pump every client other than `active` without blocking (keep-alive, chat buffering).
    fn pump_others(&mut self, active: &str) {
        let now = Instant::now();
        for (label, c) in self.clients.iter_mut() {
            if label != active {
                let _ = c.pump(now);
            }
        }
    }

    /// Pump `label` (and keep the others alive) until `check` is met, fails, or `timeout` passes.
    fn wait(
        &mut self,
        label: &str,
        timeout: Duration,
        mut check: impl FnMut(&mut Client) -> Check,
        why: impl Fn(&Client) -> String,
    ) -> Result<String> {
        let deadline = Instant::now() + timeout;
        loop {
            {
                let c = self
                    .clients
                    .get_mut(label)
                    .ok_or_else(|| anyhow!("[{label}] is not logged in"))?;
                match check(c) {
                    Check::Met(d) => return Ok(d),
                    Check::Failed(e) => bail!(e),
                    Check::Pending => {}
                }
                if let Some(e) = c.closed() {
                    bail!("connection closed: {e}");
                }
                if Instant::now() >= deadline {
                    bail!("timed out after {:.1}s: {}", timeout.as_secs_f32(), why(c));
                }
                c.pump((Instant::now() + Duration::from_millis(50)).min(deadline))?;
            }
            self.pump_others(label);
        }
    }

    fn client(&mut self, label: &str) -> Result<&mut Client> {
        self.clients
            .get_mut(label)
            .ok_or_else(|| anyhow!("[{label}] is not logged in (add a `login` line first)"))
    }

    /// A met expectation's `matches` named groups become variables.
    fn capture(&mut self, label: &str, what: &ExpectKind) {
        let re = match what {
            ExpectKind::Wnl { re, .. } | ExpectKind::Chat { re, .. } => re.as_ref(),
            _ => None,
        };
        let Some(re) = re else { return };
        let Some(text) = self.clients.get(label).and_then(|c| c.model.last_text.clone()) else {
            return;
        };
        if let Some(caps) = re.re.captures(&text) {
            for name in re.re.capture_names().flatten() {
                if let Some(m) = caps.name(name) {
                    self.vars.insert(name.to_string(), m.as_str().to_string());
                }
            }
        }
    }

    pub fn vars(&self) -> &BTreeMap<String, String> {
        &self.vars
    }

    fn run_step(&mut self, step: &Step) -> Result<String> {
        self.run_cmd(step.client.as_str(), &step.cmd)
    }

    fn run_cmd(&mut self, label: &str, cmd: &Cmd) -> Result<String> {
        let st = self.cfg.step_timeout;
        match cmd {
            Cmd::Set { var, value } => {
                let v = expand_runtime(value, &self.vars)?;
                self.vars.insert(var.clone(), v.clone());
                Ok(format!("{var} = {v}"))
            }
            Cmd::Check { left, op, right } => {
                let l = left
                    .value(&self.vars)
                    .ok_or_else(|| anyhow!("{left:?} has no value (not captured, or no such field)"))?;
                let r = right
                    .value(&self.vars)
                    .ok_or_else(|| anyhow!("{right:?} has no value (not captured, or no such field)"))?;
                if op.holds(&l, &r)? {
                    Ok(format!("{l} {op:?} {r}"))
                } else {
                    bail!("not {l} {op:?} {r}")
                }
            }
            Cmd::Deferred(line) => {
                let expanded = expand_runtime(line, &self.vars)?;
                let cmd = parse_cmd(&expanded)?;
                let d = self.run_cmd(label, &cmd)?;
                Ok(if d.is_empty() { format!("ran: {expanded}") } else { format!("{d} (ran: {expanded})") })
            }
            Cmd::Try(line) => {
                let r = parse_line(line).and_then(|cmd| self.run_cmd(label, &cmd));
                match r {
                    Ok(d) => Ok(d),
                    Err(e) => Ok(format!("{SKIP}{e:#}")),
                }
            }
            Cmd::When { var, line } => {
                if !self.vars.contains_key(var) {
                    // `set why_<var> <reason>` names why it may be missing (e.g. a server patch not live yet)
                    return Ok(match self.vars.get(&format!("why_{var}")) {
                        Some(why) => format!("{SKIP}{why} ({var} is not set)"),
                        None => format!("{SKIP}{var} is not set"),
                    });
                }
                let cmd = parse_line(line)?;
                self.run_cmd(label, &cmd)
            }
            Cmd::Reject { what, within } => {
                self.client(label)?;
                let d = within.unwrap_or(st);
                let r = self.wait(
                    label,
                    d,
                    |c| match c.model.check(what) {
                        Check::Met(found) => Check::Failed(format!("unexpected: {found}")),
                        _ => Check::Pending,
                    },
                    |_| String::new(),
                );
                match r {
                    Err(e) if e.to_string().starts_with("timed out") => {
                        Ok(format!("nothing matched in {:.1}s", d.as_secs_f32()))
                    }
                    Err(e) => Err(e),
                    Ok(d) => bail!("unexpected: {d}"),
                }
            }
            Cmd::Login { character } => {
                if self.clients.get(label).is_some_and(|c| c.in_world()) {
                    bail!("[{label}] is already in the world");
                }
                if let Some(old) = self.clients.remove(label) {
                    drop(old);
                }
                let cfg = self.client_config(label)?;
                let mut c = match Client::connect(cfg) {
                    Ok(c) => c,
                    Err(e) => {
                        self.no_entry = true;
                        return Err(e);
                    }
                };
                let name = match c.enter_world(character.as_deref()) {
                    Ok(n) => n,
                    Err(e) => {
                        self.no_entry = true;
                        self.clients.insert(label.to_string(), c);
                        self.snapshot(label);
                        self.clients.remove(label);
                        return Err(e);
                    }
                };
                let t = c.timings.clone();
                self.clients.insert(label.to_string(), c);
                self.snapshot(label);
                Ok(format!(
                    "in world as {name} on {} (auth {}ms, world {}ms, enter {}ms)",
                    self.clients[label].realm.clone().unwrap_or_default(),
                    t.auth_ms,
                    t.world_ms,
                    t.enter_world_ms.unwrap_or(0)
                ))
            }
            Cmd::Logout => {
                self.client(label)?.logout_start()?;
                let r = self.wait(
                    label,
                    self.cfg.logout_timeout,
                    |c| c.logout_state(),
                    |_| {
                        "no SMSG_LOGOUT_COMPLETE (not in a rested area? a normal logout takes 20s)"
                            .into()
                    },
                );
                self.snapshot(label);
                if let Some(mut c) = self.clients.remove(label) {
                    c.close();
                }
                r
            }
            Cmd::Say(t) => self.client(label)?.say(t).map(|_| String::new()),
            Cmd::Yell(t) => self.client(label)?.yell(t).map(|_| String::new()),
            Cmd::Whisper { to, text } => {
                self.client(label)?.whisper(to, text).map(|_| String::new())
            }
            Cmd::Join { channel, password } => self
                .client(label)?
                .join(channel, password)
                .map(|_| String::new()),
            Cmd::Leave(ch) => self.client(label)?.leave(ch).map(|_| String::new()),
            Cmd::SayChannel { channel, text } => self
                .client(label)?
                .say_channel(channel, text)
                .map(|_| String::new()),
            Cmd::Wait(d) => {
                let deadline = Instant::now() + *d;
                while Instant::now() < deadline {
                    for c in self.clients.values_mut() {
                        c.pump((Instant::now() + Duration::from_millis(20)).min(deadline))?;
                    }
                    if self.clients.is_empty() {
                        std::thread::sleep(deadline.saturating_duration_since(Instant::now()));
                    }
                }
                Ok(String::new())
            }
            Cmd::FindNpc { entry, within } => {
                let entry = *entry;
                self.client(label)?;
                self.wait(
                    label,
                    within.unwrap_or(st),
                    |c| match c.try_find_npc(entry) {
                        Some(d) => Check::Met(d),
                        None => Check::Pending,
                    },
                    move |c| {
                        format!(
                            "creature {entry} not in view ({} units in view; stand near it first, e.g. `.go xyz` as a GM)",
                            c.units_in_view()
                        )
                    },
                )
            }
            Cmd::TargetNpc(entry) => self.client(label)?.target_npc(*entry),
            Cmd::VendorList => self.client(label)?.vendor_list(),
            Cmd::Buy { entry, count } => self.client(label)?.buy(*entry, *count),
            Cmd::TargetSelf => self.client(label)?.target_self(),
            Cmd::QuestReward { quest, choice } => self.client(label)?.quest_reward(*quest, *choice),
            Cmd::BgJoin(map) => self.client(label)?.bg_join(*map),
            Cmd::BgAccept => self.client(label)?.bg_accept(),
            Cmd::BgLeave => self.client(label)?.bg_leave(),
            Cmd::Expect { what, within } => {
                self.client(label)?;
                let what2 = what.clone();
                let d = self.wait(
                    label,
                    within.unwrap_or(st),
                    |c| c.model.check(what),
                    move |c| c.model.why_not(&what2),
                )?;
                self.capture(label, what);
                Ok(d)
            }
        }
    }

    /// Run one scenario; afterwards any client still in the world logs out (not counted).
    pub fn run(&mut self, sc: &Scenario) -> ScenarioReport {
        let t0 = Instant::now();
        let mut steps = Vec::new();
        let mut broken = false;
        for step in &sc.steps {
            if broken {
                steps.push(StepReport {
                    line: step.line,
                    client: step.client.clone(),
                    step: step.text.clone(),
                    ok: false,
                    skipped: false,
                    ms: 0,
                    detail: "skipped: an earlier login failed".into(),
                });
                continue;
            }
            let t = Instant::now();
            let r = self.run_step(step);
            let ms = t.elapsed().as_millis() as u64;
            let (ok, detail) = match r {
                Ok(d) => (true, d),
                Err(e) => (false, format!("{e:#}")),
            };
            if !ok && matches!(step.cmd, Cmd::Login { .. }) {
                broken = true;
            }
            if self.cfg.primary.verbose {
                eprintln!(
                    "{} {}:{} [{}] {} ({ms} ms){}",
                    if !ok { "FAIL" } else if detail.starts_with(SKIP) { "SKIP" } else { "PASS" },
                    sc.name,
                    step.line,
                    step.client,
                    step.text,
                    if detail.is_empty() {
                        String::new()
                    } else {
                        format!(": {detail}")
                    }
                );
            }
            let skipped = ok && detail.starts_with(SKIP);
            steps.push(StepReport {
                line: step.line,
                client: step.client.clone(),
                step: step.text.clone(),
                ok,
                skipped,
                ms,
                detail,
            });
        }
        // Cleanup: leave nobody standing in the world.
        let labels: Vec<String> = self.clients.keys().cloned().collect();
        for label in labels {
            let in_world = self.clients.get(&label).is_some_and(|c| c.in_world());
            if in_world {
                if let Ok(c) = self.client(&label) {
                    let _ = c.logout_start();
                }
                let _ = self.wait(
                    &label,
                    self.cfg.logout_timeout,
                    |c| c.logout_state(),
                    |_| String::new(),
                );
            }
            self.snapshot(&label);
            if let Some(mut c) = self.clients.remove(&label) {
                c.close();
            }
        }
        let skipped = steps
            .iter()
            .filter(|s| s.detail.starts_with("skipped:"))
            .count();
        let pass = steps.iter().filter(|s| s.ok && !s.skipped).count();
        let soft = steps.iter().filter(|s| s.skipped).count();
        ScenarioReport {
            name: sc.name.clone(),
            pass,
            fail: steps.len() - pass - soft,
            skipped,
            ms: t0.elapsed().as_millis() as u64,
            steps,
        }
    }

    pub fn finish(self, scenarios: Vec<ScenarioReport>, started: Instant) -> Report {
        let pass = scenarios.iter().map(|s| s.pass).sum();
        let fail = scenarios.iter().map(|s| s.fail).sum();
        let failures: Vec<String> = scenarios
            .iter()
            .flat_map(|s| {
                s.steps.iter().filter(|st| !st.ok).map(move |st| {
                    let first = st.detail.lines().next().unwrap_or("");
                    format!(
                        "{}:{} [{}] {}: {}",
                        s.name, st.line, st.client, st.step, first
                    )
                })
            })
            .collect();
        let exit = if self.no_entry {
            EXIT_NO_ENTRY
        } else if fail > 0 {
            EXIT_FAIL
        } else {
            EXIT_OK
        };
        let clients: Vec<ClientReport> = self.seen.values().cloned().collect();
        let primary = self.seen.get("a");
        Report {
            tool: "heraldlite",
            version: env!("CARGO_PKG_VERSION"),
            mode: self.cfg.mode_name.clone(),
            target: self.cfg.target.clone(),
            ok: exit == EXIT_OK,
            exit,
            pass,
            fail,
            failures,
            characters: primary.map(|p| p.characters.clone()).unwrap_or_default(),
            ms: started.elapsed().as_millis() as u64,
            clients,
            scenarios,
            vars: self.vars.clone(),
        }
    }
}

/// The scenario run when none is given: get in, look around, get out.
pub fn default_scenario() -> Scenario {
    let text = "login\nlogout\n";
    crate::scenario::parse("(built-in login)", text, &|_| None).expect("built-in scenario parses")
}
