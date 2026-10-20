# Streams, creators and "now playing"

Who is streaming Open Vanilla, the creators who make videos about it, a monthly creator leaderboard,
a ● LIVE mark in game for streamers who want one, and an opt-in "what I'm listening to" line on
Persona profiles.

```
Twitch Helix ─┐                       ┌─> www: streamers.html, creators.html, the "Live now" strip
YouTube v3 ───┼─> tools/streams_fetch.py ─> streams.json ─┤   (https://<realm>/community/streams.json)
TikTok (opt) ─┘   every 5 min (timer)     (+ private      └─> Herald (bot/herald_streams.py)
realm: GET /api/creator/links ──┘          state file)          .wnl livestreamers A;B  (SOAP, 5 min)
   ^ players link channels on                                        │
     /ow/creator-link.html                     world server (0009) ──┘ LV A;B -> Social/Live.lua
```

## Data: `streams.json`

Written by `tools/streams_fetch.py` to the Herald's public folder and served by the realm's Caddy at
`/community/streams.json` (CORS open, 30 s cache). The website reads that URL; `?mock=1` on any page
reads `www/community/streams.mock.json` instead (`python3 tools/streams_fetch.py --mock` regenerates
it), `?src=<url>` any other copy. The repo's `www/community/streams.json` is an empty placeholder.

```
{"updated": iso,
 "live":      [{platform, id, channel, creator, title, viewers, thumbnail, url, embed, started}],
 "scheduled": [{… scheduled}],                        YouTube premieres and upcoming streams
 "videos":    [{platform, id, channel, creator, title, thumbnail, url, embed, published,
                kind: "video"|"short", duration, topics: [...], classes: [...]}],
 "creators":  [{name, platforms: [...], links: {platform: url}, badge, topics, live}],
 "leaderboard": {"month": "YYYY-MM", "rows": [{creator, hours, peak, avg, videos, rank}]},
 "ingame":    [{character, platform}]}               only creators who opted in (see below)
```

`embed` is `{type: twitch, channel}`, `{type: youtube, id}`, `{type: tiktok, id, url}` or
`{type: kick, channel}`; the pages turn it into the platform's official player
(`player.twitch.tv` with `parent=`, `youtube-nocookie.com/embed`, `tiktok.com/player/v1`,
`player.kick.com`) only when a visitor clicks. Topics and classes are keyword matches on the title,
description and tags. Shorts are videos of 3 minutes or less (YouTube) and every TikTok.

Leaderboard maths (`accumulate`/`leaderboard`, unit-tested): every pass credits each live broadcast
(one stream id) from max(its start time, the month's start, what was already counted) until now,
plus viewer-seconds for that span at the current viewer count (a time-weighted average), and keeps
the peak; a simulcast on two platforms adds both broadcasts' hours. Open Vanilla videos count once, in
the month they were published. Months are UTC; 13 are kept in the private state file
(`STREAMS_STATE`, mode 600, never in the site folder). Sorted by hours, then peak, then videos; the
top 50 are published.

## Sources and what each platform allows

| Platform | What we use | Limits |
|---|---|---|
| Twitch | Helix with an **app token** (client credentials, `TWITCH_CLIENT_ID`/`SECRET`): `streams?user_login=` for linked/curated channels, `search/channels?live_only` for "Open Vanilla", `streams?game_id=18122` filtered by title; `users?login=` for proofs | 800 points/min; a pass uses a handful |
| YouTube | Data API v3 key: `channels`, `playlistItems` (uploads), `videos` (live/upcoming/duration), `search` for "Open Vanilla" at most every `YT_SEARCH_MINUTES` (60) | 10,000 units/day. The two searches cost 100 each, hourly: 4,800/day; the rest is about 1 unit per curated/linked channel per pass (288 passes/day), so ~8,000/day with 10 channels. Raise `YT_SEARCH_MINUTES` or ask Google for more quota as the list grows |
| TikTok | **Display API** only: a creator signs in to TikTok (Login Kit) and grants `user.info.basic` + `video.list`; we then list *their own public videos* (`/v2/video/list/`) | No search, no live status, nothing about other accounts (the Research API is for academic researchers only). Access tokens last 24 h, refresh tokens 365 days; the fetcher refreshes them. Everyone else's TikTok is a plain profile link on their creator card |
| Kick | Profile links only | No stable public API we rely on |

Nothing is re-uploaded or proxied: thumbnails are the platforms' own image URLs (loaded with
`referrerpolicy=no-referrer`), players are their embeds.

Connecting a TikTok creator (staff, once per creator): register a TikTok app (Login Kit + Display
API), set `TIKTOK_CLIENT_KEY`, `TIKTOK_CLIENT_SECRET`, `TIKTOK_REDIRECT_URI` (a URL registered with
the app; TikTok shows the `code` in its query string) and `TIKTOK_TOKENS_FILE` in
`/etc/openvanilla-streams.env`, then

```
sudo -u herald env $(cat /etc/openvanilla-streams.env | xargs) python3 /opt/openvanilla-streams/streams_fetch.py --tiktok-connect @handle
#   -> a link for the creator; they sign in and send back the code from the address bar
sudo -u herald env $(cat /etc/openvanilla-streams.env | xargs) python3 /opt/openvanilla-streams/streams_fetch.py --tiktok-connect @handle --code CODE
```

## Creators: curated and linked

`www/community/creators.yml` has two parts. **Curated** (above the marker line) is edited by staff
and follows the repo (the cron pulls it hourly). **Linked** (below the marker) is rewritten every
pass from the realm service's staff-only `GET /api/creator/links`.

Players link channels on the realm: `https://play.openvanilla.app/ow/creator-link.html`
(`realm/www/creator-link.html`, page layer) talks to wenilla-realm pending patch
`realm/patches/pending/0015-openvanilla-creators.patch`:

* `GET/POST/DELETE /api/creator/link` (signed in; POST/DELETE need the `X-CSRF-Token` the GET
  returns): one channel per platform per account, one account per channel, handles validated with
  the fetcher's rules, the in-game character checked against the account's own characters.
* `GET /api/creator/links` (`Authorization: Bearer $CREATOR_EXPORT_TOKEN`; 404 while unset).

**Proof of ownership.** Each account gets a code `OW-XXXXXX`. A linked channel is used (card,
leaderboard, LIVE mark) only after the fetcher saw that code on the channel: the Twitch "About" text
or a live title, the YouTube channel description. TikTok counts as proven once the creator
connected TikTok (they signed in to it). Kick is never auto-proven: staff add Kick channels to the
curated list. Proofs are remembered per (platform, channel, code); a pending link is looked at
again at most every 15 minutes. The link page shows "listed" once the channel appears in
`streams.json`.

## In game: the ● LIVE mark

All of these must be true: the creator linked a channel, named one of their own characters and
ticked "Show me as LIVE" on the link page; the channel is proven and live right now; the player
switched on Social → settings → **Show me as LIVE** (off by default; the addon sends
`.wnl liveopt 1`). Herald pushes the names every 5 minutes (`bot/herald_streams.py`; a stale file
clears the list after 20 minutes); the world server (`realm/mangos/pending/0009-openvanilla-live.patch`)
keeps only online, opted-in characters and broadcasts `LV Name;Name`. `Social/Live.lua` shows the
mark in friends, /who, the Dungeons board, the player tooltip and Persona (badge `Persona_Live`,
profile plate `Persona_LiveBadge`); `/live` lists who is live and where to watch.

## Now playing ("Share what I'm listening to")

Off by default everywhere; only title and artist are shared ("Title - Artist", 80 characters, no
colour codes), on the player's Persona profile/tooltip as "Listening: …", over Persona's channel
like its other fields. Others can hide the line (Persona setting "Show what others listen to").
No audio, no player radio, no links in game.

**Desktop** (`launcher/nowplaying.py`, Settings → Privacy in the launcher): every 10 s the launcher
reads the Windows media session (optional `winsdk` or `winrt-Windows.Media.Control` package) or the
player's linked Spotify (PKCE, scope `user-read-currently-playing`, redirect
`http://127.0.0.1:43129/callback`, client id `spotify_client_id` in `launcher/defaults.json`), writes
`launcher/nowplaying.json` `{title, artist, link, at, source}`, and rewrites Persona's per-character
SavedVariables file (`Persona_NowPlaying = {text, at}`) in every character folder that exists —
`benilla-config/saved/<Realm>-<Char>/Persona.lua` for the Open Vanilla client and
`WTF/Account/*/<Realm>/<Char>/SavedVariables/Persona.lua` for a 1.12 install. The honest limit: a
running 1.12 client cannot be told anything, so the game sees the song **when the character enters
the world**, and Persona shows it for 10 minutes; a later song shows after the next login.

**Web** (`realm/www/nowplaying.js`, the game page's ☰ menu → "♫ Listening"): a browser tab cannot
see the system's media session, so the sources are the player's Spotify (PKCE in a popup via
`ow/nowplaying-callback.html`, needs the realm's Spotify app id in `ow/nowplaying.json`; a Spotify app
in development mode serves only the 25 accounts added to it), typing "Title - Artist", or another
same-origin page/extension (`window.owNowPlaying.set`, `postMessage {type: 'openvanilla:nowplaying'}`,
the `ow:np` localStorage key). Here updates are live: `Persona.SetListening` is called through
`wenilla.lua()` on every change and after each world entry. The desktop launcher's reader does not
reach a browser tab.

## Deploy

1. Realm service: apply pending `0015` with the others, set `CREATOR_EXPORT_TOKEN`
   (`openssl rand -hex 24`), restart. Page layer files ship with the hot-patch.
2. `bash hetzner/streams_cron.sh install` (root), fill `/etc/openvanilla-streams.env` (Twitch, YouTube,
   the same `CREATOR_EXPORT_TOKEN`, `REALM_URL`), `systemctl start openvanilla-streams` once and check
   `journalctl -u openvanilla-streams`.
3. Herald: nothing to set (`STREAMS_INGAME=1` is the default; it reads
   `<HERALD_PUBLIC_DIR>/streams.json`).
4. World server: pending `0009` with the next image.

## Tests

* `python3 -m unittest tests.test_streams_fetch tests.test_herald_streams tests.test_nowplaying`
* `xvfb-run -a python3.12 -m unittest tests.test_nowplaying_gui`
* `node tests/nowplaying_test.mjs`
* `lua5.1 devkit/sim/run_tests.lua live`
* `cargo test -p wenilla-realm --test creators` (on a worktree with 0001–0012 + 0015)
