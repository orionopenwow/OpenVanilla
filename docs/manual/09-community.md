slug: community
title: Community, Discord and Herald
kicker: Chapter 9 · Together
summary: The Discord server and its gate, Herald the bot, world chat between Discord and the game, tickets, reports, and how tips work.

## The Discord server {#discord}

The Open Vanilla Discord is where the community talks, gets help and hears news first. It's also how you get a realm account: Discord sign-in creates it (see [Getting started](start.html#account)).

| Category | Channels |
| --- | --- |
| The Gate | #welcome |
| Start here | #arrivals, #announcements, #patch-notes, #roadmap, #server-status, #support-the-realm, #faq |
| Community | #general, #introductions, #looking-for-group, #trade, #guild-recruitment, #screenshots-and-clips, #creators, #events, #off-topic |
| Guides & classes | forums: class-discussion, guides, professions |
| The realm | #world (bridged to the in-game World channel), #server-firsts, #level-60s |
| Help | forums: help, bug-reports, suggestions |
| Voice | Tavern, Dungeon 1–3, Raid, Stream, AFK |

#looking-for-group and #trade have a one-minute slow mode; #guild-recruitment allows one post per guild every six hours.

### Roles {#roles}

- **Access:** Outsider → Recruit → Adventurer (see the gate, next).
- **Badges:** Level 60, Trailblazer (the first 500 Adventurers, kept forever), Supporter (tipped the realm; never buys anything in game), Creator, Alpha Tester, Beta Tester, Guild Master.
- **Faction and class:** Alliance or Horde, plus your main class. Pick them with the buttons and menu in #welcome; your name takes your class colour.
- **Staff:** Founder, Admin, Developer, Game Master, Moderator. Staff will never ask for your password.

## The gate: Outsider, Recruit, Adventurer {#gate}

New members start as **Outsiders** and see only #welcome. This keeps bots and raids out.

1. **Enter the gate.** Press the button in #welcome and answer a random question about the rules (four choices). A wrong answer means a 30-second wait; three misses lock the gate for 15 minutes. Outsiders who never pass are removed after 48 hours.
2. **Recruit.** You can now read Start Here, ask in help, pick your faction and class, and press **Create my account**.
3. **Adventurer.** Creating your realm account with **Sign in with Discord** makes you an Adventurer: full access, and Herald announces you in #arrivals (silently: no pings, ever) with your adventurer number, class and faction.

> **Note:** If many people join at once (8 within a minute), Herald raises a **raid shield**: the gate closes and invites pause for about 15 quiet minutes. Just try again later.

## Herald {#herald}

Herald is Open Vanilla's bot. In Discord he runs the gate, #arrivals and the live #server-status message (online or offline and for how long, players online, Adventurers by faction), bridges world chat and passes tickets to staff. In the game he is a character too: **Herald, a Human Hunter**, who signs in to test every update (graphics, art, frame rate, sign-in, vendors, trade) before players see it. He never does PvP, never plays the economy, never races for server firsts.

### Herald's Discord commands {#herald-commands}

| Command | Who | What it does |
| --- | --- | --- |
| `/status` | Everyone | Is the realm up? |
| `/census` | Everyone | Alliance vs Horde, adventurer and recruit counts, classes |
| `/herald` | Everyone | Ask Herald to proclaim something |
| `/feed show` / `/feed hide` | Everyone | Show your name and avatar on the website's new-adventurer feed (default: "A new adventurer") |
| `/waitlist` | Everyone | Your place in line, when sign-ups open in waves |
| `/guild discord #channel` | Guild officers | Link a Discord channel to your guild's in-game chat (see below) |
| `/guild unlink #channel` | Guild officers | Remove that link |
| `/tickets`, `/wave`, `/lockdown`, `/promote`, `/bridge`, `/art` | Staff | Ticket queue, sign-up waves, raid shield, promotions, chat bridge, live art |

You can also DM Herald: `appeal <character> <text>` appeals a moderation decision.

### Let Herald play {#herald-autopilot}

**Herald Autopilot** can play your character for you: a desktop app (`Herald Autopilot.bat`) and, in game, the Herald addon's **Let Herald play** button or `/herald` (and `/herald stop` or **Take back control**). It drives the realm's own playerbot self-bot with rules and a gear simulator. It isn't an AI chatbot and doesn't hide from staff. Autoplay is currently off on the official realm; it works in the offline demo and on test and your own realms. See [herald.html](../herald.html) for the showcase.

## World chat between Discord and the game {#world-chat}

The in-game **World** tab and Discord's #world are one conversation.

- In game: type `/world <text>` or `/4 <text>`, or press Enter with the World tab open. Discord lines show as `[D] Name: text`. Lost the tab? `/cpchat world` brings it back.
- In Discord: Adventurers and staff can talk into the game from #world (one message every 3 seconds, 12 a minute, 255 bytes).
- Mutes and ignore lists work both ways.

### Link your guild's chat {#guild-link}

1. In Discord, a guild officer types `/guild discord #your-channel`. Herald replies with a 6-digit code.
2. In game, the guild master or an officer types `/guildlink <code>`.
3. Guild chat and that channel are now bridged. `/guild unlink #your-channel` ends it.

## Get help: tickets {#tickets}

Stuck in a wall, dead in a bad spot, talents broken? Open a ticket in game: **Help → Talk to a GM**.

Herald posts it to the staff queue within about 30 seconds with a suggested fix (unstuck, revive, reset talents, reply). When a GM approves, it runs on the realm, you get an in-game mail saying what was done, and the ticket closes. Can't log in at all? Post in the **help** forum on Discord instead.

## Report a bug {#bugs}

Use the **bug-reports** forum on Discord: what happened, what you expected, the steps to make it happen again, and a screenshot if you can. Staff can turn a good report straight into a tracked issue. Security problems go privately instead: see [security.html](../security.html).

## Report a player {#report-player}

- **In game:** right-click their name → **Report**. The report includes the chat around it, so staff see context.
- **On the website:** realms, Workshop addons and streams have a report option.

Herald sorts reports and suggests an action; **humans decide** (dismiss, warn, mute, kick, ban). The only things Herald does by itself are hiding repeated spam and a 10-minute mute for hard spam or gold selling, and both can be undone. Appeal with `/appeal <text>` in game or a DM to Herald.

## Tips: supporting the realm {#tips}

Open Vanilla is free and run by volunteers. Tips keep it that way.

- **Where:** [ko-fi.com/orionvanilla](https://ko-fi.com/orionvanilla) (card or PayPal, once or monthly), also linked from **Support the realm** on the site and in the launcher.
- **Where it goes:** hosting first, then fixes and features, community developers, Herald's test runs and community goals. The site's **Starfall Giving** section shows the buckets and the public receipts.
- **What you get:** the **Supporter** role on Discord and a vote on what gets built next.

> **Never:** Tips never buy power, items or game time. Not now, not ever.
