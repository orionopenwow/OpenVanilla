slug: classic-plus
title: In-game features: the Vanilla Remastered addons
kicker: Chapter 6 · Play
summary: Every addon that comes with Open Vanilla, how to open it, what its settings do, and how to switch any of it off for pure Vanilla.

Open Vanilla ships with the **Vanilla Remastered** addons, a suite that modernises the Vanilla interface without changing what the game is: a better quest log and map, one-bag inventory, a social window, a group-finder board, achievements, meters and more. Every piece can be switched off, alone or all at once.

> **Note:** Some features need the realm's help (quest pins, threat numbers, achievements). On a realm that doesn't support them, those parts simply stay quiet.

## Switching addons on and off {#addons-window}

Open the **AddOns** window with `/addons` (or `/cplus`), or **Esc → AddOns**.

- Left: every addon with an on/off switch. Right: the selected addon's settings.
- Bottom: **Enable All**, **Pure Vanilla** (everything off, stock interface), and **Close**.
- `/vanilla` toggles pure Vanilla from anywhere.

The **Game Menu** button at the end of the menu bar holds the Open Vanilla tools list: Meters, Threat, Bags, Raid tools, Persona, Workshop and the AddOns window.

### First-time setup {#setup-presets}

A few seconds after your first login, a window offers three presets. Reopen it any time with `/setup`.

| Preset | What's on |
| --- | --- |
| **Light** | Quests, chat, bags, loot, mail, vendor helper, Social, Essentials |
| **Recommended** | Light, plus Talents, Achievements, Dungeons, Casting, Prices, Raid and Guilds |
| **Everything** | Recommended, plus Meters, Threat, Plates, Guild Hub, Persona and Assistant |

### First-login defaults {#defaults}

Applied once on a new character, then they're ordinary settings: instant quest text, auto-accept quests (hold Shift to read), auto loot on (Shift loots by hand), camera distance up to 50 yards, floating names on, nameplates off (V for enemies, Shift-V for friends). Auto turn-in is **off**.

`/cpdefaults` shows them; `/cpdefaults loot` (or `text`, `accept`, `turnin`, `camera`, `names`, `plates`, `combat`) toggles one; `/cpdefaults reset` re-applies all.

### Moving and skinning windows {#move-skin}

- `/move` (or `/unlock`): drag any frame to move it, Shift + mouse wheel to scale, right-click to reset.
- `/skin classic`, `/skin brass` or `/skin slick` changes the Vanilla Remastered window style.
- `/wnl reset` puts every Vanilla Remastered window back in its default place.

## Quests, map and the waypoint arrow {#quests}

- **Quest log on L:** two panes, search, filters, sorting, abandon with undo, and a **Completed** history page.
- **Tracker:** objectives on a parchment page under the minimap.
- **Map pins:** gold for objectives, green for quest givers, red for turn-ins, on the world map and minimap.
- **Service icons:** repair, sell, flight masters, innkeepers, trainers and bankers.
- **Minimap ring:** a carved ring with a compass rose and coordinates. Styles: Wildwood, Stone & Leather, Iron & Oak, Runestone, Dwarven Bronze. Right-click the rose for tracking.

### The waypoint arrow {#arrow}

An arrow on screen points to your target with the distance in yards. It can point at the nearest objective by itself, and at your corpse when you die.

- `/way 42.5 65 Goldshire` sets a waypoint (x, y, optional name); `/way clear` removes it.
- `/quests arrow` toggles the arrow; `/compass` toggles the ring; `/compass theme <name>` changes its style.

| Setting | What it does |
| --- | --- |
| Waypoint arrow | Show the arrow |
| Point at the nearest objective | Pick a target by itself |
| Point at my corpse | Lead you back after dying |
| Chime on arrival | A sound when you get there |
| Arrow size | Scale |
| Turn in automatically / Pick the best reward | Optional automation (off by default) |

## Bags, bank and gear sets {#bags}

All your bags in one window with live search, quality borders and money in the footer. Lanes keep things tidy: **Bags**, **To open** (Star Pouches, lockboxes), **Reagent pouch**, **Ammo & quiver**, **Soul pouch**.

- Open with **B** or the bag buttons, or `/bags`. `/bags bank` shows your bank: it's remembered per character, so you can browse it anywhere.

**Gear sets:** `/gear` opens the panel; `/gear save <name>`, `/gear <name>` to wear it, `/gear delete <name>`, `/gear list`.

## Loot {#loot}

Every item on one list, with money from every corpse added up on one line. Click to loot, Shift-click to link, Ctrl-click to try on. "x3" means the realm merged loot from several corpses. With auto loot on, items go straight to your bags and one chat line sums it up; anything that doesn't fit stays and the window opens. Settings: **Use the standard loot window**, **Open at the mouse**, **One line for auto loot**.

## Social: friends, guild, group, who {#social}

Press **O** (or `/social`). Tabs: **Friends** (online first, with notes), **Guild** (roster, MOTD, invites), **Group** (roles, ready check, the Dungeons board), **Who** (filters, whisper, invite), **Ignore** (one list, with notes) and **Recent** (people you grouped, traded or duelled with). Keys 1–6 switch tabs while you hover the window.

You also get online and level-up toasts, and a presence status (Away, Busy, Looking for group). Social's settings hold **Show me as LIVE** (see [streams](website.html#live-mark)) and your **Armory** privacy (see [the Armory](website.html#armory-privacy)); `/armory` prints your setting and link.

## Guilds: the finder and the Guild Hub {#guilds}

- **Guild Finder** (`/guilds`): guilds post their focus, minimum level and pitch; you filter, search and apply in one click (it whispers the officer who posted it). It works on any realm.
- **Guild Hub** (`/gh`): one window to run a guild, with tabs for roster, recruiting, applications, events (calendar, sign-ups, reminders), bank log, requests, DKP, loot council, history, MOTD and officer notes. `/gh tick` awards attendance DKP (officers).

## Dungeons: the group board {#dungeons}

A board, not a queue: nobody is teleported, invites are normal invites. List yourself or your group with a role (Tank, Healer, Damage) and a note, browse by dungeon, and ask a leader to join. **Getting there** shows the entrance and a meeting point; people you ran with go to **Recent**.

`/lfg` opens it (`/lfg browse`, `/lfg list`, `/lfg recent`, `/lfg off` to remove your listing).

## Chat {#chat}

A restyled chat with five themes (slate, parchment, midnight, wildwood, glass), timestamps, short channel names, class colours, clickable links, mention highlights, spam control (repeats collapsed, gold sellers hidden), a copy box, whisper tabs and 1,000 lines of history.

- `/cpchat theme <name>`, `/cpchat copy`, `/cpchat settings`, or right-click a chat tab.
- In an empty input line, **Tab** cycles Say → Party → Raid → Guild → World (Shift+Tab goes back).
- **World chat**, shared with Discord: see [Community](community.html#world-chat).

## Mail {#mail}

At a mailbox: **Open All** (pauses when bags are full; skips cash-on-delivery unless you Shift-click and confirm), **Return All**, tick boxes for several letters, Alt-click bag items to attach (several items go as "Subject (1/3)"...), attachment search, and name suggestions from your alts, friends and guild. `/mail open`, `/mail return`, `/mail stop`. Mail between characters on the same account arrives instantly on Vanilla Remastered realms.

## Talents and two specs {#talents}

- **Reset Talents** button, free, out of combat and outside instances (it asks first).
- **Two specs:** tabs on the talent frame; switching takes a 5-second cast. Name them as you like.
- **Planner:** save builds and share them as codes.
- New spell ranks you learn on level-up appear as a toast.

`/talents` opens the planner; `/talents 1` or `/talents 2` switches spec; `/talents reset`.

## Achievements {#achievements}

388 achievements across levelling, quests, exploration, dungeons, professions, reputation and PvP: points only, never power. Open with **Y** or `/ach`.

- A banner when you earn one, a tracker for up to five under your quests, realm-first announcements, chat links, and a featured achievement on your Persona.
- `/ach compare <name>` compares with another player.

## Meters, threat, casting and prices {#combat-tools}

| Addon | What it shows | Open with |
| --- | --- | --- |
| **Meters** | Damage, healing, overhealing, damage taken, deaths with a recap, interrupts, dispels, crowd control; 25 past fights | `/meters` (or `/dps`); `/meters report party` posts a summary |
| **Threat** | Exact threat on your target from the realm, with a pull warning at 110% (melee) or 130% (range) of the tank | `/threat` |
| **Casting** | Cast bars on your target and on enemy nameplates | `/casting` to place the bar |
| **Prices** | Market price (7-day median from auction pages you browse), vendor price per item and stack | `/prices` |

## Nameplates {#plates}

Vanilla Remastered plates are a cased health bar with a level cap coloured by difficulty (a skull for bosses) and names in reaction colours. Your target's debuffs show with coloured borders and timers. Out of combat, only your target has a plate. **V** shows enemy plates, **Shift-V** friendly ones; `/plates` rescans.

Useful settings: **Plates above heads** (with a height slider, so plates stay out of the way of models), **Stack overlapping plates**, **Fade other plates**, **Hide idle plates**, **Click a plate to target**, **Enemy plates only in combat**.

## Essentials: the small helpers {#essentials}

Cooldown numbers on buttons, red out-of-range and blue out-of-mana buttons, reagent and ammo counts, auto dismount and stand up, a smarter `/cast` with conditions like `[mod:shift] [target=mouseover] [help]`, keybind mode (`/kb`: hover a button, press a key), estimated aura timers, and accessibility: a colour-blind palette, interface scale and text size (`/ess access`). `/ess` opens it.

## Raid tools {#raid}

Raid markers, a ready check with a live board, and a pull countdown. `/rally` toggles the panel; `/rally check`; `/pull` (10 seconds) or `/pull 5`; `/rally cancel`.

## Vendor helper {#vendor}

Sells grey items and repairs your gear when you open a merchant (both on by default), with one summary line. The gold **Scrap** button and `/vendor` do it by hand.

## Persona: roleplay profiles {#persona}

Build a roleplay profile: name, title, pronouns, age, height and build, home, motto, a crest, appearance, a bio, an out-of-character note and a picture. Others see it in tooltips, as a status gem on your portrait and in the **Directory**.

- `/rp` opens your target's profile (or yours); `/rp edit`; `/rp list` for the Directory.
- Status: `/rp ic` (in character), `/rp ooc`, `/rp lfrp` (looking for roleplay), `/rp st` (storyteller). Right-click the minimap button to cycle.

Other players' text is shown as plain text, and people on your ignore list are hidden both ways.

## Assistant, Herald and Node {#helpers}

- **Assistant** (`/assistant`): starter prompts for an AI agent you run outside the game. See [Connect an AI](ai.html#assistant).
- **Herald** (`/herald` or the minimap button): let Herald play your character with goals like Level up, Quest, Gather, Explore; `/herald stop` takes back control. Only where the realm allows it (Play Solo and your own server do). See [Community](community.html#herald-autopilot).
- **Node** (`/node`, Esc → Become a Node): explains the node network; the launcher turns it on or off.

## Reporting from the game {#report}

**Report…** is on right-click menus, chat names, Social, Persona, Dungeons and Guilds, or use `/report`. Pick a reason (spam, harassment, cheating, gold seller, name, other) and add a note; the recent chat lines go with it. One report every 30 seconds, ten an hour. `/appeal <text>` appeals a decision. People, not bots, decide every action.

## Command cheat sheet {#commands}

| Command | Opens |
| --- | --- |
| `/addons`, `/setup`, `/vanilla` | AddOns window, presets, pure Vanilla |
| `/quests`, `/way x y`, `/compass` | Quest log, waypoint, minimap ring |
| `/bags`, `/gear` | Bags and bank, gear sets |
| `/social`, `/guilds`, `/gh`, `/lfg` | Social, Guild Finder, Guild Hub, Dungeons |
| `/cpchat`, `/world` | Chat settings, World chat |
| `/talents`, `/ach` | Talents and specs, achievements |
| `/meters`, `/threat`, `/casting`, `/prices` | Combat and market tools |
| `/plates`, `/ess`, `/kb`, `/rally`, `/pull` | Plates, helpers, keybinds, raid tools |
| `/rp`, `/assistant`, `/herald`, `/node` | Persona, Assistant, Herald, Node |
| `/move`, `/skin`, `/wnl reset` | Move frames, window style, reset positions |
| `/report`, `/appeal`, `/live`, `/armory` | Reports, appeals, live streamers, Armory privacy |
| `/wf`, `/arena` | Warfront (on the Warfront realm) |
