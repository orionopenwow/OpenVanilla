# Legend v1 — portable, signed character records

Status: v1, stable. Licence: this text is CC0 (public domain). The reference code (`legend.py`, `legend.js`, `legend_issue.py`, `legend.html`) is MIT.

A **Legend** is a small JSON file in which an Open Vanilla realm says "this character exists on my realm and here is its record", signed with the realm's Ed25519 key. Anyone can check it: other realms, armory sites, a streamer's page. Nobody needs an account or an API key.

Keep this in mind:

- A Legend proves **which realm said it** and that nobody changed it since. It does **not** prove the realm is honest. A realm can sign anything about its own characters.
- Deciding which realms to trust (official, community, unknown) is the job of a directory or of each site that shows Legends. It is not part of this standard.

## 1. Canonical JSON

Signatures cover a canonical form of the JSON, so the file can be pretty-printed or re-ordered without breaking it.

- Encoding: UTF-8.
- Values: objects, arrays, strings, integers, `true`, `false`, `null`. **No floats.** Integers must be in −(2^53−1) … 2^53−1 so every language reads them the same.
- Object keys are sorted by Unicode **code point** (not UTF-16 code unit; this matters for characters above U+FFFF). Duplicate keys are not allowed.
- No whitespace between tokens. Separators are `,` and `:`.
- Strings: write characters as-is (no `\u` escaping of non-ASCII). Escape only `"` → `\"`, `\` → `\\`, and control characters U+0000–U+001F. Use `\n \r \t \b \f` for those five; all other control characters use `\u00XX` with lowercase hex. `/` and U+007F are not escaped. Lone surrogates are not allowed.
- Integers are written in plain decimal, no `+`, no leading zeros, `-0` is `0`.

Example: `{"b":1,"a":[true,null],"A":"é"}` → `{"A":"é","a":[true,null],"b":1}`

## 2. Realm key file

Each realm publishes its public keys at:

```
https://<realm-host>/.well-known/openvanilla-legend.json
```

```json
{"legend":1,
 "realm":{"host":"duels.openvanilla.app","name":"Duels"},
 "keys":[{"kid":"JPbtasv-EAnAMNfK","alg":"Ed25519","pub":"Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc","since":1760000000,"until":null}],
 "revoked":[]}
```

- `pub`: the 32-byte Ed25519 public key, base64url without padding.
- `kid`: the first 16 characters of `base64url_nopad(sha256(pub))`.
- `since` / `until`: Unix seconds. The key is valid for documents with `since <= issued` and (`until` is null or `issued < until`).
- `revoked`: a list of `kid` strings. Documents signed by a revoked key are invalid, whatever their date.
- Serve it with `Content-Type: application/json` and `Access-Control-Allow-Origin: *` so browser verifiers can read it. Serve your Legend files the same way.

**Rotating keys:** add the new key, set `until` on the old one to the switch-over time, and re-sign. Old Legends stay valid. **Compromised key:** put its `kid` in `revoked` and re-sign everything with a new key.

## 3. Legend document

```json
{"legend":1,
 "kind":"character",
 "realm":"duels.openvanilla.app",
 "kid":"JPbtasv-EAnAMNfK",
 "issued":1760900000,
 "serial":1,
 "prev":null,
 "subject":{"id":"duels.openvanilla.app/4242","name":"Elúne","race":"Night Elf","class":"Druid","gender":"female","level":60},
 "hero":"ovh1.GVSN6lA0SzCD8nQfZIyrChuVy5ERLpDJNQT1xssI-Sg",
 "records":{"duels":{"rating":1712,"best":1740,"wins":31,"losses":12}},
 "sig":"cTrxtrY-2BwhFQVM6nNljKS6w_AXDl4WpjGnGS52gS_tagm7oC3n927Rsb-fRcEXzkgYDTXPDbAiezdVRQggDQ"}
```

| Field | Meaning |
|---|---|
| `legend` | Format version, `1`. |
| `kind` | `"character"` in v1. |
| `realm` | Host name of the signing realm (lowercase, no port, no path). |
| `kid` | Which realm key signed it. |
| `issued` | Unix seconds when it was signed. |
| `serial` | Starts at 1, goes up by 1 for this character each time the realm re-signs it. |
| `prev` | `base64url_nopad(sha256(canonical(previous document including its sig)))`, or `null` for serial 1. Lets anyone chain a character's history. |
| `subject.id` | `<realm>/<character guid>`. Must start with `realm + "/"`. |
| `subject.*` | `name`, `race`, `class` (English names), `gender` (`male`/`female`), `level`. |
| `hero` | The player's Hero ID if they opted in, else `null`. |
| `records` | Per-mode records. `duels` has `rating`, `best`, `wins`, `losses`. Realms may add other keys here (e.g. `"arena"`); they are covered by the signature and verifiers that don't know them should ignore them. |
| `sig` | Ed25519 signature, 64 bytes, base64url without padding. |

**Signing bytes:**

```
"openvanilla-legend-v1\n" + canonical(document without the "sig" key)
```

Sign those bytes with Ed25519 (RFC 8032, pure, no pre-hash).

## 4. How to verify

1. Parse the JSON. Check `legend == 1`, `realm` is a host name, `issued` is an integer, `kid` and `sig` are strings, `hero` is null or a well-formed Hero ID, and for `kind == "character"` that `subject.id` starts with `realm + "/"`.
2. Fetch `https://<realm>/.well-known/openvanilla-legend.json` over HTTPS. Its `realm.host` must equal the document's `realm`. Never take keys from anywhere the document points to.
3. If `kid` is in `revoked`, fail.
4. Find the key with that `kid`. Check `alg == "Ed25519"` and that `kid` matches its `pub`.
5. Check `since <= issued` and (`until` is null or `issued < until`).
6. Rebuild the signing bytes and verify `sig` with `pub`.

A verifier reports: **valid or invalid** (with a reason), the **realm host**, the **issued time**, and **whether a Hero ID is present**.

Where you found the file does not matter: a Legend copied to another site still verifies, because the keys always come from the realm named inside it.

## 5. Hero IDs (opt-in player identity)

A player can hold a **Hero Key**, a secret line they keep:

```
ovk1.<key_id>.<base64url 32-byte secret>
```

From it:

```
seed    = HKDF-SHA256(ikm = secret, salt = "openvanilla-hero-v1", info = "ed25519-seed", L = 32)
keypair = Ed25519 key from seed
Hero ID = "ovh1." + base64url_nopad(public key)
```

`key_id` is a label for the player's own use; it does not change the Hero ID.

A **hero proof** shows that the holder of a Hero ID agrees to something. The verifier picks a message (e.g. `challenge:<random nonce>`); the player signs:

```
"openvanilla-hero-v1\n" + message
```

and returns the base64url signature. Anyone can check it against the Hero ID. A realm uses this to let a player link their Hero ID to an account; after that, the realm puts the Hero ID into that account's Legends. One Hero ID across several realms lets a site show "same player" without any realm sharing account data.

## 6. Privacy

- Hero IDs are **opt-in**. If a player has not linked one, `hero` is `null`.
- Documents never contain IP addresses, account ids, e-mail addresses or login names. `subject.id` uses the character's number on the realm, not the account.
- A Hero ID is a public key. It links characters the player chose to link, nothing more. A player who wants separate identities uses separate Hero Keys.
- Never ask players to paste a Hero Key into a website. Only Hero IDs and signatures should travel.

## 7. Versioning

- `legend` is the format version. A verifier must reject versions it does not know.
- New optional fields in `records` (or new record types) are not a version change.
- Changes to canonical JSON, signing bytes, required fields or verification rules mean `legend: 2`, with a new signing prefix (`openvanilla-legend-v2\n`).
- Other `kind` values may be defined later; a v1 verifier still checks the signature for them but should show them as unknown.

## 8. Test vectors

The full set is in `vectors.json` (canonical JSON cases, two chained documents, a tampered one). All base64url below is unpadded.

**Hero Key** (secret = bytes `0x00 0x01 … 0x1f`):

```
key line   ovk1.TESTKEY001.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8
HKDF seed  b85b762a49e33e85c9069e054b807016d5cc5049dbfa5bbbacf681f7e37735e0
Hero ID    ovh1.GVSN6lA0SzCD8nQfZIyrChuVy5ERLpDJNQT1xssI-Sg
message    challenge:abc
signature  N-HLEYmR5g_4FCo_me8yAcKGnFyzI2zaH9K0paTp1zG4itrnvcjtF9CtCh1do9HWOQXvKT81o2C7K0mE3usdCA
```

**Realm key** (seed = bytes `0x20 0x21 … 0x3f`, host `duels.openvanilla.app`, `since` 1760000000):

```
pub   Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc
kid   JPbtasv-EAnAMNfK
```

**Sample document**: the one in section 3. Its signing bytes are:

```
openvanilla-legend-v1
{"hero":"ovh1.GVSN6lA0SzCD8nQfZIyrChuVy5ERLpDJNQT1xssI-Sg","issued":1760900000,"kid":"JPbtasv-EAnAMNfK","kind":"character","legend":1,"prev":null,"realm":"duels.openvanilla.app","records":{"duels":{"best":1740,"losses":12,"rating":1712,"wins":31}},"serial":1,"subject":{"class":"Druid","gender":"female","id":"duels.openvanilla.app/4242","level":60,"name":"Elúne","race":"Night Elf"}}
```

```
sig                        cTrxtrY-2BwhFQVM6nNljKS6w_AXDl4WpjGnGS52gS_tagm7oC3n927Rsb-fRcEXzkgYDTXPDbAiezdVRQggDQ
prev for the next document 4jydkFM73M5XVZytdLedg1s-xksfJi8wT8MBIOXSlU4
```

Ed25519 is deterministic, so a correct implementation reproduces these signatures byte for byte.

## 9. Reference code

- `legend.py`: Python 3.8+, no dependencies. `python3 legend.py verify FILE_OR_URL`, `python3 legend.py hero KEYLINE [--sign MESSAGE]`.
- `legend.js`: ES module for browsers and Node 18+, using WebCrypto Ed25519 and HKDF. Browsers need WebCrypto Ed25519: current Chrome/Edge (137+), Firefox (129+) and Safari (17+).
- `legend_issue.py`: realm-side issuer for cron.
- `legend.html`: a self-contained verifier page (`?u=<legend url>`, `&embed=1` for a compact card).
