// The Open Vanilla community on Root: roles, channel groups, channels and the bot's info posts.
// Mirrors bot/discord_setup.py + discord_content.py, minus the Discord-only gate (Root has no
// Outsider/Recruit step: members join, pick their faction and class roles themselves, and talk).
// Edit freely and re-run: the setup only adds what's missing and never deletes anything.

export const SITE = "https://openvanilla.app/";
export const PLAY = "https://play.openvanilla.app/";
export const HOST_GUIDE = "https://openvanilla.app/host.html";
export const KOFI = "https://ko-fi.com/orionvanilla";

export const COMMUNITY_NAME = "Open Vanilla";
export const COMMUNITY_DESCRIPTION =
  "Classic Vanilla in your browser, free. Play Vanilla or Vanilla Remastered, build and share mods, host your own realm.";

// Role names on Root: letters, numbers and hyphens only. Colours follow item quality.
//   staff: gets moderation powers ("admin" = everything)   self: members can give it to themselves
export type RoleDef = { name: string; color: string; staff?: "admin" | "mod"; self?: boolean };
export const ROLES: RoleDef[] = [
  { name: "Founder", color: "#FF8000", staff: "admin" },
  { name: "Admin", color: "#A335EE", staff: "admin" },
  { name: "Developer", color: "#A335EE" },
  { name: "Game-Master", color: "#0070DD", staff: "mod" },
  { name: "Moderator", color: "#0070DD", staff: "mod" },
  { name: "Level-60", color: "#E6CC80" },
  { name: "Trailblazer", color: "#FFD100" },
  { name: "Supporter", color: "#FF7EB6" },
  { name: "Creator", color: "#1ABC9C" },
  { name: "Alpha-Tester", color: "#1EFF00" },
  { name: "Beta-Tester", color: "#1EFF00" },
  { name: "Guild-Master", color: "#B08D57" },
  { name: "Adventurer", color: "#C9A227" },
  { name: "Alliance", color: "#2459C7", self: true },
  { name: "Horde", color: "#B30000", self: true },
  { name: "Warrior", color: "#C69B6D", self: true },
  { name: "Paladin", color: "#F48CBA", self: true },
  { name: "Hunter", color: "#AAD372", self: true },
  { name: "Rogue", color: "#FFF468", self: true },
  { name: "Priest", color: "#FFFFFF", self: true },
  { name: "Shaman", color: "#0070DD", self: true },
  { name: "Mage", color: "#3FC7EB", self: true },
  { name: "Warlock", color: "#8788EE", self: true },
  { name: "Druid", color: "#FF7C0A", self: true },
];
export const STAFF = ROLES.filter((r) => r.staff).map((r) => r.name);
export const TESTERS = ["Alpha-Tester", "Beta-Tester"];

// audience: everyone    everyone reads and talks
//           readonly    everyone reads, only staff and the bot post
//           testers     testers (and staff) only
//           staff       staff only
export type Kind = "text" | "threads" | "voice";
export type ChannelDef = { kind: Kind; name: string; topic: string; audience?: Audience };
export type Audience = "everyone" | "readonly" | "testers" | "staff";
export type GroupDef = { name: string; audience: Audience; channels: ChannelDef[] };

export const LAYOUT: GroupDef[] = [
  { name: "Start Here", audience: "readonly", channels: [
    { kind: "text", name: "welcome", topic: "What Open Vanilla is, the rules, and how to start playing." },
    { kind: "text", name: "announcements", topic: "News from the Open Vanilla team." },
    { kind: "text", name: "patch-notes", topic: "Every change to the realm, launcher and site." },
    { kind: "text", name: "roadmap", topic: "What's coming next." },
    { kind: "text", name: "server-status", topic: "Is the realm up right now?" },
    { kind: "text", name: "support-the-realm", topic: "Tips keep Open Vanilla free. Tips never buy power." },
    { kind: "text", name: "faq", topic: "Common questions. Still stuck? Post in help." },
  ]},
  { name: "Community", audience: "everyone", channels: [
    { kind: "text", name: "general", topic: "Talk about anything Open Vanilla." },
    { kind: "text", name: "introductions", topic: "New here? Say hi." },
    { kind: "text", name: "looking-for-group", topic: "Find a group: dungeon, level range, role." },
    { kind: "text", name: "trade", topic: "Buy, sell, crafting requests. In-game gold only." },
    { kind: "text", name: "guild-recruitment", topic: "Find your guild, or grow it." },
    { kind: "text", name: "screenshots-and-clips", topic: "Your best moments in Azeroth." },
    { kind: "text", name: "creators", topic: "Addons, models, mounts, repacks, art and streams." },
    { kind: "text", name: "events", topic: "Community events, contests and giveaways." },
    { kind: "text", name: "off-topic", topic: "Everything else." },
  ]},
  { name: "Guides and Classes", audience: "everyone", channels: [
    { kind: "threads", name: "class-discussion", topic: "Talents, gear and tactics. One thread per topic." },
    { kind: "threads", name: "guides", topic: "Levelling, dungeon and profession guides from players." },
    { kind: "threads", name: "professions", topic: "Recipes, crafters for hire, gathering spots." },
  ]},
  { name: "The Realm", audience: "everyone", channels: [
    { kind: "text", name: "world", topic: "Talk about life on the realm." },
    { kind: "text", name: "server-firsts", topic: "Realm firsts.", audience: "readonly" },
    { kind: "text", name: "level-60s", topic: "Congratulations to every new 60.", audience: "readonly" },
  ]},
  { name: "Help", audience: "everyone", channels: [
    { kind: "threads", name: "help", topic: "One thread per problem." },
    { kind: "threads", name: "bug-reports", topic: "What happened, what you expected, steps to repeat, a screenshot." },
    { kind: "threads", name: "suggestions", topic: "Ideas for the realm, launcher or site." },
  ]},
  { name: "Testing", audience: "testers", channels: [
    { kind: "text", name: "alpha-lounge", topic: "For testers in the current wave." },
    { kind: "text", name: "alpha-feedback", topic: "What worked, what broke, what felt off." },
  ]},
  { name: "Voice", audience: "everyone", channels: [
    { kind: "voice", name: "Tavern", topic: "" }, { kind: "voice", name: "Dungeon 1", topic: "" },
    { kind: "voice", name: "Dungeon 2", topic: "" }, { kind: "voice", name: "Dungeon 3", topic: "" },
    { kind: "voice", name: "Raid", topic: "" }, { kind: "voice", name: "Stream", topic: "" },
    { kind: "voice", name: "AFK", topic: "" },
  ]},
  { name: "Staff", audience: "staff", channels: [
    { kind: "text", name: "staff-chat", topic: "Staff only." },
    { kind: "text", name: "alerts", topic: "Realm down / back alerts." },
    { kind: "text", name: "moderation", topic: "Player reports. People decide every action." },
    { kind: "text", name: "mod-log", topic: "Moderation audit trail." },
  ]},
];

// The bot's info posts, one per channel. The first line is the post's title: a channel that already
// has a message starting with that line is left alone, so re-running never posts twice.
export const POSTS: Record<string, string> = {
  welcome:
`**Welcome to Open Vanilla**
A free, community-run home for classic World of Warcraft: play in your browser or with the Open Vanilla Launcher on our Vanilla Remastered realm, solo offline, or on a realm you host.

**Start playing**
• In your browser: ${PLAY} (press **Play free as a guest**, no sign-up)
• Desktop launcher and everything else: ${SITE}
• Host your own realm: ${HOST_GUIDE}

**Pick your roles**
Open your profile and give yourself your faction (**Alliance** or **Horde**) and your main class. They colour your name and help people find a group.

**The rules**
1. Be kind. No harassment, slurs, or hate. Disagree with ideas, not people.
2. No NSFW, gore, or shock content, anywhere.
3. No spam, ads, or self-promotion outside **creators**.
4. No cheats, exploits, or real-money trading. Found an exploit? Message a Game Master privately.
5. Never share your password, with anyone, including staff.
6. Staff have the final say. Disagree? Message an Admin calmly.

Open Vanilla is a fan project and isn't affiliated with or endorsed by Blizzard.`,

  roadmap:
`**Roadmap**
• **After the next realm restart:** skills learned as you level, free respec, dual spec, a starter pet for hunters, AoE looting and a gentler level curve.
• **Building toward:** community goals that unlock rewards for **everyone** when they're met: mounts, pets, redone zones, content patches. Never power for money.
• **How we grow:** in waves, so the realm stays smooth. Each step opens once the last one runs a week without problems.
News lands in **announcements**; every change is listed in **patch-notes**.`,

  "server-status":
`**Server Status**
Live realm status is on the website: ${SITE}
Realm offline? Staff are alerted automatically. Check **announcements** for news; no need to post about it.`,

  "support-the-realm":
`**Support the Realm**
Open Vanilla is free and run by volunteers. Tips keep it that way: they pay for **hosting first**, then fixes and new features.
• **How to tip:** on Ko-fi (card or PayPal): ${KOFI}
• **Where it goes:** every tip gets a **public receipt**, so anyone can see what it paid for.
• **What you get:** the **Supporter** role and a vote on what gets built next.
• **What you never get:** power, items or game time. Not now, not ever.`,

  faq:
`**FAQ**
**What is Open Vanilla?** A free, community-run home for classic WoW: play in your browser or with the launcher on our Vanilla Remastered realm, solo offline, or on a realm you host.
**Does it cost anything?** No. Tips help with hosting and **never** buy power, items or game time.
**Is this official?** No. It's a fan project, not affiliated with or endorsed by Blizzard.
**How do I start?** Open ${PLAY} and press **Play free as a guest**. To keep your heroes, sign in with Discord from the game's top bar.
**What's Vanilla Remastered?** Vanilla with the race and class pairs modern WoW allows, better defaults, built-in addons, and fixes that respect the original game.
**What do I need?** Browser: Chrome or Edge with a recent graphics driver. Desktop: Windows, the launcher from ${SITE} and your own Vanilla Client v1.3 game files.
**The game won't load?** Start a thread in **help** with your browser or launcher version and a screenshot.
**Can I make things for Open Vanilla?** Yes: addons and repacks go in the Workshop on the website. Show them off in **creators**.
**Can I host my own realm?** Yes, with Open Vanilla Server: ${HOST_GUIDE}`,

  introductions:
`**Introductions**
New here? Say hello. Copy this:
\`\`\`
Name:
Main class:
Played vanilla on:
What I want to do here:
\`\`\``,

  "looking-for-group":
`**Looking for Group**
One post per group; delete or edit it when the group is full. Grab a **Dungeon** voice channel for your party.
\`\`\`
LFG / LFM | Dungeon | Level | Need: Tank / Healer / DPS | When
\`\`\``,

  trade:
`**Trade**
In-game gold and items only. Real-money trading, account sales or gold selling is a permanent ban here and in game.
\`\`\`
WTS / WTB | Item | Price | Contact
\`\`\``,

  "guild-recruitment":
`**Guild Recruitment**
One post per guild every 6 hours.
\`\`\`
Guild:
Faction:
Style: Casual / Raiding / PvP / RP
Raid times:
Looking for:
Contact:
\`\`\``,

  creators:
`**Creators**
Show what you've made for Open Vanilla: addons, repacks, models and mounts, art, guides, videos and streams.
• **Addons and repacks:** publish them in the Workshop on ${SITE} so players can install them in one click, then post the link here.
• **Models and mounts:** the Model Porter turns your own rigged .glb into a Vanilla creature or mount. Only share work that's yours.
• **Creator role:** make something people use and staff will give you the **Creator** role.`,

  help:
`**Help: read me first**
One thread per problem, so answers stay findable.
A good thread has: what you were doing · what you expected · what happened · browser or launcher · a screenshot.
Never share your password, with anyone, including staff.`,

  "bug-reports":
`**Bug Reports: read me first**
One bug per thread. Search first; if it's already reported, add a reaction and any new details.
\`\`\`
What happened:
What I expected:
Steps to repeat:
Browser or launcher + version:
Screenshot / clip:
\`\`\`
Found something abusable? Don't post it publicly: message a Game Master.`,

  suggestions:
`**Suggestions: read me first**
One idea per thread: the problem it solves, how it would work, who it's for. React to the ideas you like.`,

  "alpha-lounge":
`**Alpha Lounge**
You're here because you're helping us test. Thank you.
• Play normally, try odd things, and tell us what breaks or feels wrong.
• Quick reactions: **alpha-feedback**. Real bugs: a thread in **bug-reports**.
• Expect restarts, wipes before launch, and rough edges. Wipes are always announced first.`,

  "staff-chat":
`**Staff Handbook**
• **Moderating:** 1. remove the message. 2. warn privately. 3. kick. 4. ban for slurs, scams, cheating or real-money trading. Log every action in **mod-log**.
• **Player reports** from the game arrive in Discord's moderation desk for now; a person decides every action.
• **Never** ask players for passwords, share admin logins, or promise dates that aren't announced.`,
};
