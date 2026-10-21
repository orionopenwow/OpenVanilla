# Open Vanilla changelog
(build_repack.py turns the newest sections into the launcher's patch notes: "## Section" headers, "- item" lines.)

## New in 1.36.0
- Mangos patch 0022: a Star Pouch opened again with its loot all taken is spent, not an empty loot window.
- Herald loots alone; addon files can't be read stale after a deploy; bug reports carry fps and ms.

## New in 1.35.0
- Realm patches 0033-0034: Herald no longer goes AFK or through hills; Alt+Enter full screen.
- Players' reports: the Game Menu button clicks again, one hub at a time, Herald pauses while you shop.
- Server images built ahead on main, so a Release doesn't wait for them.
- Tools/prepush.py: every generated file rebuilt from its sources before a push; devkit/check.py checks it.
- Retire one-time and superseded scripts.

## New in 1.34.0
- A.
- Meters: bare reset and cog glyphs; tabs sized to their labels.
- Meters: the bars reach the inner dark box's right edge.
- Meters: plain bars again, tabs a little right, tools tucked in, centred title, Fight time.
- Meters: a weathered iron frame round each bar.
- Meters: tabs as drawn - rounder, a gold rim and glowing line on the chosen one, a larger title.
- Meters: tabs, reset and cog in their places; Damage shows the total alone.
- Meters: tabs in the frame's header band, rounded; the portrait follows the mode.
- UI pictures: status bars draw their fill (as long as the value, in the bar's colour).
- Meters 1.16: a normal window, readable at a glance.
- Realm patch 0032: a guest's Hero Key is made at "Play now" and shown in game; .txt key files; /key drop fixed and behind ?debug=1.
- Swing timer under the character; the chat sits higher by default.

## New in 1.33.0
- Make every player a realm host: federated architecture, toolkit, identity and realm directory.
- Hero Key v2: Ed25519 keypair authentication (ovk2), backward-compatible seed derivation from legacy ovk1 via HKDF-SHA256, public Hero IDs (ovh1), challenge-response login, and cryptographic key rotation.
- Open Vanilla Passport: signed portable character records (passport.json) with tamper-evident prestige event hash chains (level 60, first kills, titles) and GDPR Art. 20 export compliance.
- Trust tiers and import modes: Tier 0 (Official), Tier 1 (Verified), Tier 2 (Community), Tier 3 (Unverified); Legacy display, Cosmetic import, and capped Full import.
- Realm Recipe & Composer: deterministic realm.json recipes, pack conflict linter (creatures, items, DBC rows, ADT tiles) with explicit 'which wins' resolution, realm cloning, and 'Pass the torch' succession bundles.
- Host API: unified REST contract for realm control, sleep-and-wake, player moderation, GM console, and rollback previews.
- Browser Host Console (www/host.html): Simple and Advanced modes, live realm status, separate human/bot player counts, GM console, backup previews, and one-time realm wizard.
- Launcher Host un-redirection: HOST tab reinstated in main navigation with Host for Friends and Dedicated Server tabs active.
- Armory Card & oEmbed: server-rendered SVG cards with class accents and verification badges, OpenGraph unfurls, and compliant embed generator.
- Realm directory fit-and-depth ranking: sorts by trust, curator picks, 14-day new realm slots, and uptime streaks; bots counted apart from human Hero Key sessions.
- Realm Covenant & Will (docs/REALM_COVENANT.md, www/covenant.html): non-commercial pledge, bring-your-own data, 30-90 days notice, and multi-party backup escrow.
- Workshop provenance & licence allowlist: workshop.json schema and validator enforcing CC0/CC-BY/MIT and rejecting ND/Sketchfab.
- Cloud-init configs (Hetzner CX23, Oracle arm64) and Pocket Realm 4-week spike specification.
- Forge MCP expansions: added forge_host_api, forge_test_realm, and forge_drive_bot tools to Vanilla Forge.

## New in 1.32.0
- Realm patch 0031: Hero IDs, the public half of a Hero Key.
- Meters tabs in the Quests tracker's type: Friz, its gold-yellow when chosen, its parchment ink otherwise.
- Duels: on the website (DUELS_OPEN, Duels and Legend links), its patch-Z on today's Warfront one, the Duels addon in patch-Z.
- A.
- Meters: clean tab edges (pixel-drawn 3-slice tabs, crisp reset and cog frames).
- Meters: rounded Nunito text, drop shadows, cleaner tabs.
- Meters polish: no bar borders, rows touching, Arial Narrow text with a soft shadow.
- Mangos 0020 after review: groups through the world thread, unstuck only when travelling, player groups left alone.
- Meters: built from the owner's art kit (stone window, gold border and corners, kit tabs and buttons, scrollbar with arrows, rimmed fills).
- Site: Discord is for the community, not for signing in.
- GM console: Herald's last 24 hours (fights, deaths per 100 fights, close calls, fights in a group, by class, stuck hot spots with .go).
- Mangos 0020: Herald's brain.
- Meters: flat, flush rows like the reference (fill behind icon and name, outlined text, stone frame).
- Meters: matched to the reference window (bar art, row text, header, tabs, fonts).
- Realm_up: apply classicplus_herald_rotations.sql with the other Classic+ SQL.
- Herald: class rotations by level band (27 custom combat strategies, 171 lines).
- Warfront: a TESTING state in the realm list and a mode screen before you go.
- Herald: his choices in the panel, invites from friends, class rotation by level band, fight and stuck logs.
- Meters: the bronze window (header with title menu, reset, settings and close; Damage, DPS, Healing and Deaths tabs; textured class-colour bars; gold scrollbar).
- Discord Herald speaks only when commanded: no unasked #arrivals post (HERALD_ANNOUNCE=1 brings it back).
- Manual: Host on a Mac or Linux (chapter 12), built into ovhost too.
- Host a realm on macOS and Linux: host/ovhost (Docker), portable realm_up, launcher fixes.
- UI Studio: tune every window by hand (drag, size, colour, fonts, theme, tunables, art pipeline, /move import).
- Realm patch 0030: Hero Keys, and Discord sign-in ready to retire in phases.
- Herald_selfbot.sh on: no bot-AI broadcasts (loot, kills, quests, level-ups to say, yell, guild, channels) and no AI chat on the realm.
- Herald doesn't talk.
- Loot: the auto-loot recap opens beside the cursor and out of the middle of the screen, never over your character.

## New in 1.31.0
- Bug reports also open a public GitHub issue (Herald), for suggested fixes.
- Realm patch 0028 compiles: player.rs re-exports SETTLE_HARD_CAP.
- Realm patch 0029: buffs no longer turn red when a far enemy is selected.
- Loot: the auto loot recap always shows, and stays a few seconds before it fades.

## New in 1.30.9
- Community rules page (www/rules.html), linked from the site, Terms and Privacy.
- Staff wear a small blue <GM> in chat.
- Herald: the server owner and Administrators count as staff (their #world messages reached nobody).
- Work in progress.
- Realm-image: compile Rust on the runner with a kept build cache (minutes, not ~45).
- Sign-in page: Google button right under Discord (realm patch 0027).
- Console: a hidden in-game GM window (/ovgm, /gmc), game masters only.
- GM console redesign: badges, class icons, HP bars, parchment map, server sparklines, tickets.
- Mangos 0019: GM console feed, clean names, a quiet World channel.
- Realm patch 0028: no falling through the world on load.
- Mangos 0018: falling through the world puts the player back where they last stood (bind point the second time) instead of killing them.
- Herald Lite: the scenario parse test gives HL_PLAY a duration.
- Sign in with Google (realm patch 0027).
- Everything in the browser: Workshop addons in browser play (Lua-only packages, checked by SHA-256, kept in the browser), Forge Lite (items, creatures, quests and an addon as a Forge project), and the browser.html hub.
- Bot/staff_audit.py: find and close every way a non-staff member sees the staff channels.
- Herald: no unasked Discord DMs unless HERALD_DMS=1.
- Guest sign-up limits lifted: 20 per network per hour, 50 a day, no realm-wide daily cap by default.
- GM console: every player on one page (Server.bat option G).
- Fixes from the code review of 19-20 Oct.
- Restart countdown: 'a minute or two' (the world server came back in 57 s on 20 Oct).
- Portal.html matches index.html again (one blank line); the Studio test expects the realm's name, Vanilla Remastered.
- Hetzner/bug_digest.sh: a bug digest three times a day.
- Patch-Z: Social opens only when asked, /bug <text>.
- Social opens only when asked; /bug <text> sends a report straight from chat.
- Ov_gm.sh make-admin: the game account behind a Discord sign-in gets a GM level (3 admin, 2 game master, 1 moderator, 0 player), by Discord name; in the GM menu as 10.
- GM tools and a 5-minute restart countdown in chat.
- Patch-Z: the Herald addon (rest, fight orders, status) and Chat 1.16 as committed.
- Mangos 0016: Herald picks fights he can win alone.
- Herald eats on to 90% when he has food (eating is quick); sits only below 70%.
- Herald bridge: Discord -> game failures are visible (console answers checked, warning reaction, /bridge status, start-up check, a lock reaction for members without the role); herald_up.sh re-creates the HELPDESK….
- Chat 1.16: one tab strip for docked, World, Guild and whisper tabs: nothing covers another tab or the buttons, tabs narrow then fold into rows, relaid on resize; Show World/Guild tab in the chat menu.
- Herald's panel says what he is doing: fighting, resting (health or mana %), on his way back, or playing.
- Herald rests before the next pull; the Herald check becomes a scorecard.
- Herald fights it out and loots every kill (community feedback).
- Realm telemetry, and XP x1.5 from kills as well as quests.
- Herald: a leveling profile, a stuck watchdog, and the panel on screen.
- Hetzner/playerbots_db.sh: install the bot AI's database tables on the live realm.
- World server image: link aiplayerbot.conf where the bot AI reads it.
- Hetzner/herald_check.sh: smoke-test Herald on the live realm.
- Herald_selfbot.sh on: also switch the bot AI on when it was off, with no realm bots.
- Vanilla Agents browser access: the relay at agents.openvanilla.app (agents_relay_up.sh) and the pairing page at /agents/live/.
- Herald on a player's character: also switch off the bot AI's maintenance.
- Herald Autopilot takes over a player's own character from the server.
- Herald Autopilot on the live realm: drive the character with .rndbot cmd.
- Patch-Z: tonight's addon fixes for browser players (chat tab menu, expanded chat, welcome, bug box).
- Page bridge: no-op fullscreen where the browser has none (iPhone Safari).
- Manual: the changelog link points at the home page's What's next.
- Chat: expanded view of the whole history (tab bar button, chat menu, /cpchat expand): search, live new lines, clickable links, Maximize.
- Site: launch polish - one What's next section (Warfront + realm templates), Discord numbers and LIVE chip hidden until real, no made-up player counts, unused forum modals out, trailer label, engine named benilla.
- Herald: world_chat scenario and hetzner/world_chat_check.sh - checks World chat, the Discord bridge and the bug button after a realm update.
- Addons: a one-time welcome after the first login (World chat and its Discord link, the bug button and /bug, the Discord invite; /welcome shows it again; waits for the setup window), and a new-player simulator pass.
- Launch queue: on, 80 players in the world at once (PlayerLimit 100 above it), and a While you wait grid in the queue window (desktop app, Discord #world, Agents, Forge, addons).
- Realm: World chat and its Discord bridge go live (patch 0007 and classicplus_world.sql out of pending; realm_up runs the SQL).
- Addons: the bug report box takes typing (multi-line note in a scroll frame, click to focus, Enter sends), same for the player report note; Guild and World chat tabs open a menu on right-click instead of vanishing,….
- Site: the Forge section shows Forge's in-game 3D view.
- Site: the Agents section shows the inn GIF.
- Site: Vanilla Forge (coming soon) and Vanilla Agents sections on the home page and portal.
- Realm-image: install the faster workflow.
- Vanilla Agents: the inn at work as a looping GIF, the header of the Agents page and a new README section.
- Site: Get Vanilla Data replaces the client download.
- Realm-image: build only images whose inputs changed; ccache for mangosd.
- Mangos 0014: BugCommand in namespace Wnl, where Wnl.cpp declares it.
- Mobile taps: a thumb that rolls while down still taps.
- Discord_doctor: test the sign-in page at /login (/ is the play page: 401 until signed in).
- Hetzner/discord_doctor.sh: checks the Discord sign-in settings (bot token, client secret, server, role order, redirect) without printing secrets, restarts Herald, smoke-tests Sign in with Discord, lists….
- Site: Orion's 'Made by Orion' sprite moves up to the top of the footer, centred under the Support/Discord buttons; the 'Enjoying Open Vanilla?' card fades away after 8 s (not while the mouse is on it).
- Site: the last '#' Discord links go to discord.gg/r6nj5p8U4; Server download links point at the GitHub release (downloads/ only had the old OpenWoW zip).
- Docs: READMEs say Vanilla instead of World of Warcraft / WoW / 1.12.
- Open Vanilla.

## New in 1.30.8 (Vanilla Remastered pace, and Vanilla Forge)
- Vanilla Remastered levels at a friendlier pace: quest items always drop and every group member on the quest gets their own, quest XP is 1.5x, rested XP builds five times faster at inns and capitals (and slowly by any cooking fire), and each new area explored gives at least 1% of a level.
- Flights are twice as fast and you learn your faction's flight paths as you level, the Hearthstone and single-target Blessings run on 15 minutes, weapon skills train four times faster, and abandoning an item-started quest gives the item back.
- Veteran Mentor: +20% quest XP for each other level-60 character on your account, up to +60%.
- A quest board inside every dungeon entrance takes and gives that dungeon's quests, and training dummies that whisper your DPS stand by each capital's weapon master.
- The Hearthstone, Blessing and Quests addon tooltips show the realm's real timers and XP, mentor bonus included.
- Open Vanilla's name everywhere: launcher, server window, realm and website. Your install, characters and settings stay as they are.
- New on the website: Vanilla Forge, the free creator app (make maps, creatures, quests and addons, and test them on your own PC), with a guide to running your own test server, and Vanilla Agents, your AI helpers at work in a cosy inn.
- Ko-fi link on the site, in the launcher and in the manual, for anyone who wants to chip in. Nothing that affects play is ever sold.

## New in 1.30.6
- Fixes and polish.

## New in 1.30.5
- Fixes and polish.

## New in 1.30.4
- Fixes and polish.

## New in 1.30.3
- Fixes and polish.

## New in 1.30.2 (the new logo on the website)
- The website opens with the new Open Vanilla book logo, big and sharp on every screen size.
- Releases never stop for missing patch notes again: if a version has none yet, the release writes them from what changed.

## New in 1.30.1 (a new look for Open Vanilla Server)
- Open Vanilla Server has a new look: every button matches the launcher's, with clear colours (gold to start, violet to play in your browser, red to halt everything), icons, and rounded lettering.
- The HTTPS tools sit in one tidy grid, and both address boxes have their own Save button.
- The new Open Vanilla book logo everywhere, big and front and centre on the website: launcher, realm pages, favicon and Discord too.
- Open Vanilla's name is now used everywhere you read it: the launcher, Herald Autopilot, the loading-screen tips, the website, the manual and the docs. Your install, characters and settings stay exactly as they are.
- Herald Autopilot's window shows the Open Vanilla wordmark.
- Fresh screenshots on the website and the GitHub page, taken from the current launcher, server and Herald.
- Server owners can write settings as OpenVanilla.Transmog, OpenVanilla.Warfront and so on in mangosd.conf; the old names keep working.

## New in 1.30.0 (Open Vanilla, Warfront live counts)
- Open Vanilla is now Open Vanilla: the website, launcher, addons and docs use the new name. Your install, realms, characters and settings stay exactly as they are.
- The launcher is now OpenVanilla.exe, with "Open Vanilla" shortcuts in the Start menu and on the desktop. It updates itself as usual; the launcher file under its old name stays next to it for one release so older launchers can update too.
- Warfront's arena window shows who is waiting: live queue counts for each arena mode, matches being played, and players queued for battlegrounds. The website shows Warfront's live numbers too.
- When realm bots fill empty spots in a Warfront battle, you're told as you enter. Bots never count for streaks or bounties.
- Phone sign-in with Discord opens the Discord app on Android, and finishes in the browser you started in, even when Discord comes back in a different one: match the 4-digit code and you're in.
- A new animated "Signing in" screen in the browser game.
- Phone taps on the character screens land where your finger is on any phone, with a debug view (?touchdebug=1) to help find taps a browser drops.
- Assistant, Herald and Warfront are in the Workshop with the rest of the suite.
- Transmog: collect every look you bind, save outfits and switch them anywhere, with hidden slots, weapon illusions and outfits that change by situation. It works on realms that turn it on (Warfront first), at a Transmogrifier in each capital.
- The game manual is on the website: 18 chapters, from your first login to Warfront, linked from the pages that need them.

## New in 1.20.5 (Herald Autopilot, play on your phone)
- Herald Autopilot: a new program (Herald Autopilot.bat) where Herald plays for you on realms that allow it. Pick a goal (Level up, Quest, Gather, Follow me, Dungeon), press START, and watch the live log, map and bags.
- Rules are plain sentences you change with one click ("Rest when health is below 35%"), with sensible defaults for every class.
- Sim compares two sets of stats for your class and shows what each stat is worth.
- Watch Herald play your own character, any race and any class: click Herald by the minimap (or /herald) and press Let Herald play. He runs on the realm's own bot AI; you keep your camera, chat and UI, and take back control any time. Works on Open Vanilla Server and Play Solo, and on any realm whose owner turns it on.
- Herald on your own server: Open Vanilla Server has a HERALD button. Herald logs in an account you pick on your server and plays it (a fresh Human character in Northshire for now).
- Help Herald learn: if you say yes, Herald shares anonymous run numbers (never names, chat or positions) and everyone's default rules get better. Settings shows exactly what's sent.
- Play on your phone: browser play has touch controls. A stick to move, drag to look, four action keys around the Attack button, and a tray for bags, quests, chat and the menu. The Attack button shows what a tap will do with the game's own icons: a sword for an enemy, a loot bag, a quest ! or ?, an anvil at a repair vendor.
- On a phone, the character list and character creation answer taps again, so Create New Character, Enter World and Back all work.
- Touch settings: pick how the camera and buttons work (Classic, Simple or PC), auto loot, and the interface size.
- Nameplates: out of combat only your target has a plate; the rest appear when a fight starts (Plates setting "Hide idle plates").
- The website has a new realm list, a Discord community panel with live member and online counts, and a details window for each upcoming realm (Warfront, Moonguard with player housing coming, Ascension Resurrected).
- Guest play is better protected against abuse, and linking Discord to a guest signs out any old guest logins.

- Quests has a new look: the objective tracker is a parchment page in an iron frame, with gold lettering, red seals to fold each quest (a shield once it is done) and a close seal in the corner.
- A new Vanilla Remastered loading screen.
- The website's support window and Support button have new art, and Vanilla Remastered has its own details window with an Enter Realm button.
## New in 1.17.4 (Vanilla Remastered)
- The official realm is now called Vanilla Remastered on the website, in the launcher and in Herald.
- The website's realm list shows how many players are online right now (Herald counts them every minute) and the realm's live status. The filter tabs, the ping column and the "LAN server / this PC" row are gone.
- Herald's #server-status card shows players online too.

## New in 1.17.3 (faster loading, fixed windows)
- Browser play loads much faster from far away: game data, the interface and every addon are fetched in parallel before you need them, instead of one file at a time.
- Big buildings and cities (Stormwind, Darnassus, Northshire Abbey) download all their pieces at once: no more loading bar stuck near the end.
- Persona, Social, Friends, the Guild Hub and the Guilds board open again in the browser.
- The mouse keeps working after you click the menu or another window: clicking the game takes it back.
- The chat sits a little higher, clear of the action bars, and the zone name above the minimap no longer hides behind the close button.

## New in 1.17.2 (Open Vanilla Server is back)
- Running your own realm is its own download again: OpenVanilla-Server.zip, beside the launcher on every release and on openvanilla.app/host.html.
- The launcher is for playing: the HOST tab is gone. Join any realm from REALMS, or with an invite link.
- Open Vanilla Server finds your SPP Classics install by itself (or asks once), installs what it needs on first start, sets the realm address players connect to, and removes the Play Solo login before anyone can reach it.

## New in 1.17.1 (new home)
- Open Vanilla has a new home: github.com/orionopenwow/OpenVanilla and openvanilla.app. Your launcher follows by itself.
- The client button and the client list are back on HOME, and Workshop has a new CLIENTS tab for finding and adding game clients.
- HOME is cleaner: the welcome and Herald cards are gone.
- The website introduces Herald, Open Vanilla's self-learning ranger.

## New in 1.17.0 (one launcher)
- One thing to launch: OpenVanilla.exe. It starts the game for you, keeps itself up to date in the background and shows UPDATE READY when a new version is waiting.
- One PLAY button with Online, Solo and Browser.
- Play Solo: one click downloads SPP Classics, one guided setup, then PLAY. Your own offline world with playerbots.
- Host for friends is built in: host a realm from the launcher and share an invite link. The launcher explains what your friends can see before anything starts.
- Dedicated server tools are in the launcher too (HOST, Advanced), so there's no separate server download.
- Tidy folders: AddOns (Enabled and Disabled), Realms, Screenshots, Logs and Backups, each one click away in Settings.
- News, cards and links in the launcher update live from the website.
- Meet Herald, Open Vanilla's self-learning test ranger, on the website's new Herald page.
- Activate your AI (optional): a starter kit and prompts for using your own AI coding agent to make addons and run your own realm, plus an in-game Assistant window.
- Become a Node (preview, off until the network opens): help carry the network, with privacy explained up front.

## New in 1.16.1 (sign-in)
- A new sign-in page in Open Vanilla's look, on phones and computers: the Open Vanilla logo and art, one big Sign in with Discord button, and the password form tucked away.
- Signed in once, signed in for good: no more Discord login screen on your phone when the realm already knows you. Your sign-in lasts 60 days from your last visit.
- On a phone, the Discord button can open the Discord app to approve, and a returning player gets "Continue as <name>".
- After signing in you land back on the page you were going to, and a sign-in that timed out quietly tries again once.
- Add Open Vanilla to your home screen: it has an icon and opens full screen. Browsers that can't run the game say what to use instead.
- Play free as a guest: no sign-up, no Discord needed. Your heroes stay on that device, and "Continue as guest" brings you back to them.
- Link Discord any time (the gold link at the top of the game) and your guest heroes become a full account you can use anywhere.
- For creators: the Model Porter (Model_Porter.bat). Drop a rigged, animated .glb and it becomes a 1.12 creature or a rideable mount, with its bones, animations and textures, a live preview, and a one-click "Add to Open Vanilla".

## New in 1.16.0 (community)
- Report players from any right-click menu, chat name, Social, Persona, Dungeons or Guilds. Reports carry the chat around them and go to a moderation desk; people decide every kick and ban.
- Guild Hub (/gh): roster with ranks and notes, recruitment, an events calendar with sign-ups and reminders, a bank log, DKP and loot council, and an MOTD composer.
- World chat: a new World channel bridged to the Open Vanilla Discord, with its own chat tab.
- A ● LIVE mark next to players who are streaming, and "now playing" on Persona (off unless you turn it on).
- Website: the Armory (every character and guild, public unless you choose friends-only or hidden), Streamers and Creators pages with a monthly leaderboard, and the Workshop for finding, rating and installing addons.

## New in 1.15 (addons and site: live with this update)
- Plain addon names everywhere: Meters, Quests, Bags, Prices, Vendor, Plates, Casting, Threat, Raid, Guilds, Persona.
- The Addons window has real on/off switches, room for every addon, and settings that scroll.
- Meters tracks what Details! does: damage, healing, overhealing, damage taken, deaths with a recap, interrupts, dispels, crowd control, uptime and more, with 25 past fights, boss fights kept, tabs, extra windows, a breakdown window, reports and a settings sheet behind the gear.
- Quests: the Wildwood ring is back as the minimap frame. Repair and vendor icons on the minimap, a tracking menu on the compass rose, a corpse arrow, a quest tracker, quest pins on the world map and a new quest log on L with search, filters, sorting, abandon-with-undo and history.
- Social (O): friends, guild, group, who, ignore and recent players in one window, with online and level-up toasts.
- Dungeons: a group finder board. List yourself, browse, ask to join. Nobody is teleported or pulled into a group.
- Chat: five themes (Slate by default), opaque and raised, with timestamps, short channel names, copy chat, history, mentions and spam control.
- Achievements: 388 real vanilla achievements on Y. They start counting once the realm update lands.
- Mail (Open All, Return All), a new loot window, gear sets in Bags, and Talents with a planner.
- Essentials: cooldown numbers, out-of-range colours, reagent counts, auto dismount, smarter /cast, keybind mode, aura timers and accessibility options.
- Defaults that stick: auto loot, instant quest text, auto-accept, names over heads, nameplates off (V turns them on). Nameplates end in a grey level cap and can be clicked.
- Right-click menus work again on the player, target and party frames, names and nameplates.
- Vendor sell prices on every item tooltip.
- Play Solo: a new page on the site.
- Persona, redesigned: the Character-frame look with your picture in the portrait, four guided steps (Basics, Picture, Story, Extras) with Back and Next, and a profile picture: your character, any race and sex, or a hero or creature face.
- Dungeons, Essentials, the Quest Log, Raid, the Meters breakdown and the chat copy windows now use the classic WoW dialog look (switch with /skin).
- The loading box has the Open Vanilla frame, dragon endcaps and an arcane bar.
- A tip jar on the site and in the launcher (Support the realm). Tips never buy power, items or game time.

## Waiting for the realm restart
- Skills learned as you level (no trainer), free respec, dual spec, a starter pet for hunters, AoE looting, fixed level-up silver, a gentler level curve and achievements tracking (realm/mangos/pending, realm/classicplus/pending).
- A WoW-style loading screen, sound that waits until you move, the hero logo on the login screens and a class grid that only offers allowed pairs (realm/patches/pending).

## New in 1.14.2
- Persona: roleplay profiles for every player. Name, title, appearance, bio, shares and an IC / OOC / looking-for-RP status on tooltips, your target's portrait and a player directory. Type /rp.
- Better defaults on first login: instant quest text, auto-accept quests (hold Shift to read), full camera distance and auto loot. /cpdefaults to change them.
- Weapon skills fixed for the new race and class pairs (Human, Undead and Gnome Hunters; Troll Druids).
- Character creation: the class row is 5 across with room for every class.
- The account menu folds into a small tab at the top, and the loading and login screens have new art.

## Under the hood
- Page and addon updates go live about a minute after a push, with no rebuild or restart.
- Herald, the test bot, signs in every night as a Human Hunter and reports what works.
