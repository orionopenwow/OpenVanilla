//! The autopilot only runs against Open Vanilla's own realms and local/test hosts. The list is
//! hard-coded on purpose: there is no flag to widen it.

/// Exact hosts allowed.
pub const ALLOWED_HOSTS: &[&str] = &[
    "play.openvanilla.app",
    "staging.openvanilla.app",
    // the old names, still served by the same realm while players move over
    "play.openwow.app",
    "staging.openwow.app",
    "localhost",
    "127.0.0.1",
];
/// Allowed suffixes (`*.test`, `*.localhost`).
pub const ALLOWED_SUFFIXES: &[&str] = &[".test", ".localhost"];

/// The host part of `host`, `host:port`, `[v6]:port` or a URL.
pub fn host_of(target: &str) -> String {
    let mut s = target.trim();
    if let Some(i) = s.find("://") {
        s = &s[i + 3..];
    }
    // Drop path, query and userinfo.
    if let Some(i) = s.find(['/', '?', '#']) {
        s = &s[..i];
    }
    if let Some(i) = s.rfind('@') {
        s = &s[i + 1..];
    }
    let host = if let Some(rest) = s.strip_prefix('[') {
        rest.split(']').next().unwrap_or("")
    } else {
        match s.rsplit_once(':') {
            Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) => h,
            _ => s,
        }
    };
    host.trim_end_matches('.').to_ascii_lowercase()
}

/// `Ok(())` if the target's host is on the allowlist.
pub fn check(target: &str) -> Result<(), String> {
    let h = host_of(target);
    let ok = !h.is_empty()
        && (ALLOWED_HOSTS.contains(&h.as_str())
            || ALLOWED_SUFFIXES
                .iter()
                .any(|s| h.ends_with(s) && h.len() > s.len()));
    if ok {
        Ok(())
    } else {
        Err(format!(
            "refusing to run the autopilot against {h:?}: only {} and *.test / *.localhost are allowed",
            ALLOWED_HOSTS.join(", ")
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowlist() {
        for ok in [
            "127.0.0.1",
            "127.0.0.1:3724",
            "localhost:8085",
            "https://staging.openvanilla.app",
            "https://play.openvanilla.app/",
            "PLAY.OPENVANILLA.APP:443",
            "realm.test",
            "a.b.localhost:3724",
            "https://user@staging.openvanilla.app/play?x=1",
        ] {
            assert!(check(ok).is_ok(), "{ok}");
        }
        for bad in [
            "",
            "10.0.0.5",
            "example.com",
            "play.openvanilla.app.evil.com",
            "evilplay.openvanilla.app",
            "https://openvanilla.app",
            ".test",
            "test",
            "127.0.0.2",
            "https://staging.openvanilla.app@evil.com/",
            "[::1]:3724",
            "logon.blizzard.com",
        ] {
            assert!(check(bad).is_err(), "{bad}");
        }
    }
}
