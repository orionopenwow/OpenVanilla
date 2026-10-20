//! The Open Vanilla "WNL" server channel, as `WenillaCore.lua` reads it.
//!
//! The server hook (`OpenVanilla/Wnl.cpp`) answers `.wnl <cmd>` and streams addon data as chat lines
//! whose text starts `WNL\t` (or `WNL `): normally `CHAT_MSG_PARTY` + `LANG_ADDON` from the player's
//! own guid, but WenillaCore also accepts the same text as `CHAT_MSG_SYSTEM` or a whisper from the
//! reserved sender. After the prefix comes `<TAG> <payload>`; the payload is either the body
//! itself (the `HI` greeting: `HI <version> <addon,addon,...>`) or the chunked form
//! `<seq> <i>/<n> <part>`, which is reassembled per `(tag, seq)` (`WnlFormat::Lines`, 200-byte
//! parts).

use std::collections::HashMap;

/// One complete WNL message (chunks already joined).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WnlMessage {
    /// Upper-cased tag: `HI`, `LG`, `CP`, `VG`, `VS`, `AC`, ...
    pub tag: String,
    /// The body after reassembly (for `HI`, everything after the tag).
    pub body: String,
    /// The chunk sequence number when the line was chunked.
    pub seq: Option<String>,
}

/// The payload after `WNL\t` / `WNL `, or `None` when the text is not a WNL line.
pub fn strip_prefix(text: &str) -> Option<&str> {
    text.strip_prefix("WNL\t")
        .or_else(|| text.strip_prefix("WNL "))
}

/// One parsed line before reassembly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WnlLine {
    /// A complete message (unchunked, or `1/1`).
    Whole(WnlMessage),
    /// Part `index` (1-based) of `total` for `(tag, seq)`.
    Part {
        tag: String,
        seq: String,
        index: usize,
        total: usize,
        body: String,
    },
}

/// Parse the payload after the `WNL` prefix, exactly as `W:HandlePayload` does.
pub fn parse_payload(raw: &str) -> Option<WnlLine> {
    let raw = raw
        .strip_prefix('\t')
        .or_else(|| raw.strip_prefix(' '))
        .unwrap_or(raw);
    if raw.is_empty() {
        return None;
    }
    let (tag, rest) = match raw.find(' ') {
        Some(sp) => (&raw[..sp], &raw[sp + 1..]),
        None => (raw, ""),
    };
    let tag = tag.to_ascii_uppercase();
    if tag == "HI" {
        return Some(WnlLine::Whole(WnlMessage {
            tag,
            body: rest.to_string(),
            seq: None,
        }));
    }
    // Lua pattern "^(%S+) (%d+)/(%d+) ?(.*)$"
    if let Some((seq, index, total, body)) = split_chunked(rest) {
        if total <= 1 {
            return Some(WnlLine::Whole(WnlMessage {
                tag,
                body: body.to_string(),
                seq: Some(seq.to_string()),
            }));
        }
        return Some(WnlLine::Part {
            tag,
            seq: seq.to_string(),
            index,
            total,
            body: body.to_string(),
        });
    }
    Some(WnlLine::Whole(WnlMessage {
        tag,
        body: rest.to_string(),
        seq: None,
    }))
}

fn split_chunked(rest: &str) -> Option<(&str, usize, usize, &str)> {
    let (seq, after) = rest.split_once(' ')?;
    if seq.is_empty() || seq.chars().any(char::is_whitespace) {
        return None;
    }
    let digits_end = after
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(after.len());
    if digits_end == 0 || !after[digits_end..].starts_with('/') {
        return None;
    }
    let index: usize = after[..digits_end].parse().ok()?;
    let after = &after[digits_end + 1..];
    let total_end = after
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(after.len());
    if total_end == 0 {
        return None;
    }
    let total: usize = after[..total_end].parse().ok()?;
    let mut body = &after[total_end..];
    // " ?" then ".*$": an optional single space.
    if let Some(b) = body.strip_prefix(' ') {
        body = b;
    } else if !body.is_empty() {
        // Lua's `(%d+)` is greedy and `" ?(.*)"` then takes the rest; a non-space right after
        // the digits still matches (body starts there).
    }
    Some((seq, index, total, body))
}

/// Reassembles chunked WNL lines into whole messages.
#[derive(Default, Debug)]
pub struct Reassembler {
    buffers: HashMap<(String, String), (usize, HashMap<usize, String>)>,
}

impl Reassembler {
    /// Feed one chat text; returns a whole message when one completes.
    pub fn feed_text(&mut self, text: &str) -> Option<WnlMessage> {
        let payload = strip_prefix(text)?;
        self.feed(parse_payload(payload)?)
    }

    pub fn feed(&mut self, line: WnlLine) -> Option<WnlMessage> {
        match line {
            WnlLine::Whole(m) => Some(m),
            WnlLine::Part {
                tag,
                seq,
                index,
                total,
                body,
            } => {
                let key = (tag.clone(), seq.clone());
                let entry = self
                    .buffers
                    .entry(key.clone())
                    .or_insert_with(|| (total, HashMap::new()));
                entry.1.entry(index).or_insert(body);
                if entry.1.len() >= entry.0 {
                    let (total, parts) = self.buffers.remove(&key)?;
                    let mut out = String::new();
                    for i in 1..=total {
                        out.push_str(parts.get(&i).map(String::as_str).unwrap_or(""));
                    }
                    return Some(WnlMessage {
                        tag,
                        body: out,
                        seq: Some(seq),
                    });
                }
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hi_is_never_chunked() {
        let mut r = Reassembler::default();
        let m = r
            .feed_text("WNL\tHI 1 Quests,Threat,Prices,Plates,Achievements")
            .unwrap();
        assert_eq!(m.tag, "HI");
        assert_eq!(m.body, "1 Quests,Threat,Prices,Plates,Achievements");
        assert_eq!(m.seq, None);
    }

    #[test]
    fn single_chunk() {
        let mut r = Reassembler::default();
        let m = r.feed_text("WNL\tCP 7 1/1 120,0.5,0.25,OBJ").unwrap();
        assert_eq!((m.tag.as_str(), m.body.as_str()), ("CP", "120,0.5,0.25,OBJ"));
        assert_eq!(m.seq.as_deref(), Some("7"));
    }

    #[test]
    fn space_prefix_and_lowercase_tag_are_accepted() {
        let mut r = Reassembler::default();
        let m = r.feed_text("WNL cp 1 1/1 0,0,0").unwrap();
        assert_eq!(m.tag, "CP");
        assert_eq!(m.body, "0,0,0");
    }

    #[test]
    fn non_wnl_text_is_ignored() {
        let mut r = Reassembler::default();
        assert!(r.feed_text("hello there").is_none());
        assert!(r.feed_text("WNLX CP 1 1/1 a").is_none());
        assert!(r.feed_text("WNL\t").is_none());
    }

    #[test]
    fn multi_chunk_reassembles_in_any_order() {
        let body: String = (0..450)
            .map(|i| char::from(b'a' + (i % 26) as u8))
            .collect();
        let parts: Vec<String> = body
            .as_bytes()
            .chunks(200)
            .map(|c| String::from_utf8(c.to_vec()).unwrap())
            .collect();
        assert_eq!(parts.len(), 3);
        let mut r = Reassembler::default();
        assert!(r
            .feed_text(&format!("WNL\tAC 3 3/3 {}", parts[2]))
            .is_none());
        assert!(r
            .feed_text(&format!("WNL\tAC 3 1/3 {}", parts[0]))
            .is_none());
        // a duplicate part changes nothing
        assert!(r
            .feed_text(&format!("WNL\tAC 3 1/3 {}", parts[0]))
            .is_none());
        let m = r.feed_text(&format!("WNL\tAC 3 2/3 {}", parts[1])).unwrap();
        assert_eq!(m.body, body);
    }

    #[test]
    fn empty_body_is_one_empty_part() {
        // WnlFormat::Lines: an empty body is one empty part ("clear").
        let mut r = Reassembler::default();
        let m = r.feed_text("WNL\tCP 9 1/1 ").unwrap();
        assert_eq!(m.body, "");
        let m = r.feed_text("WNL\tCP 9 1/1").unwrap();
        assert_eq!(m.body, "");
    }

    #[test]
    fn unchunked_non_hi_body_passes_through() {
        let mut r = Reassembler::default();
        let m = r.feed_text("WNL\tVG -").unwrap();
        assert_eq!((m.tag.as_str(), m.body.as_str()), ("VG", "-"));
    }
}
