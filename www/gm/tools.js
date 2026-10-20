// tools.js: the "Tools" tab. Every everyday GM job as a plain button. A tool that needs details
// (an ID, a name, an amount) asks for them in a small game-style popup, pre-filled from your
// target where that makes sense. No command text is shown; the command lives in `cmd`.
//
// A tool: { label, icon, tip, cmd, fields?, confirm?, find? }
//   cmd    — a template: {key} is replaced by that field's value; an empty optional field drops out.
//            Or a function (values, gm) => string | string[] for anything smarter.
//   fields — [{ key, label, placeholder, value, optional, type, options:[[value,label],…] }]
//            value 'target' = target name (any), 'player' = target player or you, 'me' = your name.
//   confirm — ask "are you sure" first (for destructive tools).
//   find    — adds a "Find…" link to the Loot tab's search of that kind (item, creature, object, spell, quest).
// Add your own groups/tools from custom.js with gm.addTools('Group', [...]).

const RANKS = [['hated', 'Hated'], ['hostile', 'Hostile'], ['unfriendly', 'Unfriendly'], ['neutral', 'Neutral'], ['friendly', 'Friendly'], ['honored', 'Honored'], ['revered', 'Revered'], ['exalted', 'Exalted']];
const PROFESSIONS = ['alchemy', 'blacksmithing', 'enchanting', 'engineering', 'leatherworking', 'tailoring', 'cooking', 'first aid', 'fishing', 'mining', 'herbalism', 'skinning'].map((p) => [p, p[0].toUpperCase() + p.slice(1)]);

const GROUPS = [
  ['Character', [
    { icon: '⬆', label: 'Add levels', tip: 'Level up your target, or you', fields: [{ key: 'n', label: 'How many levels', value: '1', type: 'number' }], cmd: '.levelup {n}' },
    { icon: '🎚', label: 'Set level', tip: 'Set a character to an exact level', fields: [{ key: 'name', label: 'Character', value: 'player' }, { key: 'lvl', label: 'Level', value: '60', type: 'number' }], cmd: '.character level {name} {lvl}' },
    { icon: '📖', label: 'Learn spell', tip: 'Teach a spell to your target, or you', find: 'spell', fields: [{ key: 'id', label: 'Spell ID', placeholder: 'e.g. 10' }], cmd: '.learn {id}' },
    { icon: '✂', label: 'Unlearn spell', tip: 'Remove a spell', find: 'spell', fields: [{ key: 'id', label: 'Spell ID' }], cmd: '.unlearn {id}' },
    { icon: '📚', label: 'All class spells', tip: 'Every spell and talent of your class', cmd: '.learn all_myclass' },
    { icon: '🛡', label: 'GM spells', tip: 'The default Game Master spells', cmd: '.learn all_gm' },
    { icon: '🗣', label: 'All languages', tip: 'Speak every language', cmd: '.learn all_lang' },
    { icon: '⚒', label: 'All recipes', tip: 'Every recipe of a profession, skill maxed', fields: [{ key: 'p', label: 'Profession', options: PROFESSIONS, value: 'alchemy' }], cmd: '.learn all_recipes {p}' },
    { icon: '★', label: 'Max skills', tip: 'All skills to the maximum for the level', cmd: '.maxskill' },
    { icon: '🔧', label: 'Set skill', tip: 'Set one skill value', fields: [{ key: 'id', label: 'Skill ID', placeholder: 'e.g. 171 = Alchemy' }, { key: 'v', label: 'Value', value: '300' }, { key: 'max', label: 'Max', value: '300', optional: true }], cmd: '.setskill {id} {v} {max}' },
    { icon: '✨', label: 'Add aura', tip: 'Put a spell aura on your target, or you', find: 'spell', fields: [{ key: 'id', label: 'Spell ID' }], cmd: '.aura {id}' },
    { icon: '🚫', label: 'Remove aura', tip: 'Take a spell aura off', find: 'spell', fields: [{ key: 'id', label: 'Spell ID' }], cmd: '.unaura {id}' },
    { icon: '🔥', label: 'Cast on target', tip: 'Cast any spell on your target', find: 'spell', fields: [{ key: 'id', label: 'Spell ID' }], cmd: '.cast {id}' },
    { icon: '🎭', label: 'Change model', tip: 'Turn into another model', fields: [{ key: 'id', label: 'Display ID', placeholder: 'e.g. 15369' }], cmd: '.modify morph {id}' },
    { icon: '🙂', label: 'Normal model', tip: 'Back to your own model', cmd: '.demorph' },
    { icon: '⚧', label: 'Change gender', tip: 'Male or female', fields: [{ key: 'g', label: 'Gender', options: [['male', 'Male'], ['female', 'Female']], value: 'female' }], cmd: '.modify gender {g}' },
    { icon: '🌟', label: 'Talent points', tip: 'Set unspent talent points', fields: [{ key: 'n', label: 'Points', value: '51', type: 'number' }], cmd: '.modify tp {n}' },
    { icon: '🤝', label: 'Reputation', tip: 'Set standing with a faction', find: 'faction', fields: [{ key: 'f', label: 'Faction ID', placeholder: 'e.g. 72 = Stormwind' }, { key: 'r', label: 'Standing', options: RANKS, value: 'exalted' }], cmd: '.modify rep {f} {r}' },
    { icon: '🗺', label: 'Reveal maps', tip: 'Uncover the whole world map', cmd: '.explorecheat 1' },
    { icon: '🌫', label: 'Hide maps', tip: 'Cover the world map again', cmd: '.explorecheat 0' },
    { icon: '⏱', label: 'Reset cooldowns', tip: 'Clear all spell cooldowns', cmd: '.cooldown clear' },
    { icon: '🔨', label: 'Repair gear', tip: 'Repair everything worn and carried', cmd: '.repairitems' },
    { icon: '✚', label: 'Revive', tip: 'Bring your target, or you, back to life', cmd: '.revive' },
    { icon: '☠', label: 'Kill target', tip: 'Kill the selected unit', confirm: 'Kill your target?', cmd: '.die' },
    { icon: '🕊', label: 'Stop combat', tip: 'Drop out of combat', cmd: '.combat stop' },
    { icon: '↺', label: 'Reset talents', tip: 'Refund all talent points', cmd: '.reset talents' },
    { icon: '↺', label: 'Reset stats', tip: 'Recalculate base stats', cmd: '.reset stats' },
    { icon: '⏮', label: 'Back to level 1', tip: 'Reset level, stats and talents', confirm: 'Reset your target (or you) to level 1?', cmd: '.reset level' },
    { icon: '✏', label: 'Force rename', tip: 'Make a character pick a new name at next login', fields: [{ key: 'name', label: 'Character', value: 'player' }], cmd: '.character rename {name}' },
  ]],
  ['Teleport', [
    { icon: '➜', label: 'Go to player', tip: 'Jump to a player', fields: [{ key: 'name', label: 'Player', value: 'target' }], cmd: '.goname {name}' },
    { icon: '⇠', label: 'Summon player', tip: 'Bring a player to you', fields: [{ key: 'name', label: 'Player', value: 'target' }], cmd: '.namego {name}' },
    { icon: '👥', label: 'Summon group', tip: 'Bring a player and their whole group', fields: [{ key: 'name', label: 'Player', value: 'target' }], cmd: '.groupgo {name}' },
    { icon: '📌', label: 'Send player to…', tip: 'Teleport a player to a named place', fields: [{ key: 'name', label: 'Player', value: 'target' }, { key: 'place', label: 'Place', placeholder: 'e.g. stormwind' }], cmd: '.tele name {name} {place}' },
    { icon: '🏰', label: 'Go to place', tip: 'Teleport to a named place (Stormwind, Orgrimmar, gmisland…)', fields: [{ key: 'place', label: 'Place', placeholder: 'e.g. ironforge' }], cmd: '.tele {place}' },
    { icon: '🔎', label: 'Find a place', tip: 'Search the server teleport list', fields: [{ key: 'q', label: 'Name contains', placeholder: 'e.g. storm' }], cmd: '.lookup tele {q}' },
    { icon: '👹', label: 'Go to NPC', tip: 'Jump to a creature by name', fields: [{ key: 'name', label: 'Creature name', value: 'target' }], cmd: '.go creature {name}' },
    { icon: '📦', label: 'Go to object', tip: 'Jump to a game object by its template ID', find: 'object', fields: [{ key: 'id', label: 'Object ID' }], cmd: '.go object id {id}' },
    { icon: '🧭', label: 'Go to coordinates', tip: 'Exact world coordinates', fields: [{ key: 'x', label: 'X' }, { key: 'y', label: 'Y' }, { key: 'z', label: 'Z' }, { key: 'map', label: 'Map', optional: true, placeholder: '0 Eastern Kingdoms, 1 Kalimdor' }], cmd: '.go xyz {x} {y} {z} {map}' },
    { icon: '🗺', label: 'Go to map spot', tip: 'Map percentages, like the world map shows', fields: [{ key: 'x', label: 'X (0-100)' }, { key: 'y', label: 'Y (0-100)' }, { key: 'zone', label: 'Zone ID', optional: true, placeholder: 'current zone' }], cmd: '.go zonexy {x} {y} {zone}' },
    { icon: '↩', label: 'Go back', tip: 'Return to where you were before the last teleport', cmd: '.recall' },
    { icon: '🏁', label: 'Starting area', tip: 'Back to your race\'s starting area', cmd: '.start' },
    { icon: '🏝', label: 'GM Island', tip: 'The GM island', cmd: '.tele gmisland' },
    { icon: '⚰', label: 'Nearest graveyard', tip: 'Show the nearest graveyard', cmd: '.neargrave' },
    { icon: '📍', label: 'My position', tip: 'Show your exact position in Messages', cmd: '.gps' },
  ]],
  ['Creatures', [
    { icon: '➕', label: 'Spawn NPC', tip: 'Place a creature where you stand (saved)', find: 'creature', fields: [{ key: 'id', label: 'Creature ID', placeholder: 'e.g. 448 = Hogger' }], cmd: '.npc add {id}' },
    { icon: '🗑', label: 'Delete NPC', tip: 'Remove the targeted creature for good', confirm: 'Delete the targeted creature spawn permanently?', cmd: '.npc delete' },
    { icon: '📍', label: 'Move NPC here', tip: 'Move the targeted creature\'s spawn to you', cmd: '.npc move' },
    { icon: 'ℹ', label: 'NPC info', tip: 'Details of the targeted creature', cmd: '.npc info' },
    { icon: '🎚', label: 'NPC level', tip: 'Change the targeted creature\'s level', fields: [{ key: 'n', label: 'Level', type: 'number' }], cmd: '.npc changelevel {n}' },
    { icon: '⚑', label: 'NPC faction', tip: 'Change the targeted creature\'s faction', find: 'faction', fields: [{ key: 'id', label: 'Faction ID', placeholder: '35 = friendly to all' }], cmd: '.npc factionid {id}' },
    { icon: '🎭', label: 'NPC model', tip: 'Change the targeted creature\'s model', fields: [{ key: 'id', label: 'Display ID' }], cmd: '.npc setmodel {id}' },
    { icon: '✏', label: 'Rename NPC', tip: 'Give the targeted creature a new name', fields: [{ key: 'name', label: 'New name' }], cmd: '.npc name {name}' },
    { icon: '💬', label: 'Make it say', tip: 'The targeted creature says something', fields: [{ key: 't', label: 'Text' }], cmd: '.npc say {t}' },
    { icon: '📢', label: 'Make it yell', tip: 'The targeted creature yells', fields: [{ key: 't', label: 'Text' }], cmd: '.npc yell {t}' },
    { icon: '💃', label: 'Make it emote', tip: 'Play an emote (e.g. 10 dance, 4 cheer, 11 laugh)', fields: [{ key: 'id', label: 'Emote ID', value: '10' }], cmd: '.npc playemote {id}' },
    { icon: '🐾', label: 'Follow me', tip: 'The targeted creature follows you', cmd: '.npc follow' },
    { icon: '✋', label: 'Stop following', tip: 'Stop following you', cmd: '.npc unfollow' },
    { icon: '🦁', label: 'Tame it', tip: 'Tame the targeted beast as your pet', cmd: '.npc tame' },
    { icon: '🚶', label: 'Movement', tip: 'How the targeted creature moves', fields: [{ key: 't', label: 'Movement', options: [['stay', 'Stand still'], ['random', 'Wander'], ['way', 'Waypoints']], value: 'random' }], cmd: '.npc setmovetype {t}' },
    { icon: '⭕', label: 'Wander distance', tip: 'How far it wanders', fields: [{ key: 'd', label: 'Yards', value: '5' }], cmd: '.npc spawndist {d}' },
    { icon: '⏲', label: 'Respawn time', tip: 'Seconds until it respawns', fields: [{ key: 's', label: 'Seconds', value: '300' }], cmd: '.npc spawntime {s}' },
    { icon: '♻', label: 'Respawn nearby', tip: 'Respawn the target, or everything dead nearby', cmd: '.respawn' },
    { icon: '🛒', label: 'Add to vendor', tip: 'Add an item to the targeted vendor', find: 'item', fields: [{ key: 'id', label: 'Item ID' }], cmd: '.npc additem {id}' },
    { icon: '🛒', label: 'Remove from vendor', tip: 'Take an item off the targeted vendor', find: 'item', fields: [{ key: 'id', label: 'Item ID' }], cmd: '.npc delitem {id}' },
  ]],
  ['Objects', [
    { icon: '➕', label: 'Spawn object', tip: 'Place a game object where you stand (saved)', find: 'object', fields: [{ key: 'id', label: 'Object ID' }], cmd: '.gobject add {id}' },
    { icon: '📋', label: 'Objects nearby', tip: 'List objects around you, with their IDs', fields: [{ key: 'd', label: 'Within yards', value: '10' }], cmd: '.gobject near {d}' },
    { icon: '🎯', label: 'Nearest object', tip: 'Find the nearest object (optionally by name)', fields: [{ key: 'q', label: 'Name or ID', optional: true }], cmd: '.gobject target {q}' },
    { icon: '📍', label: 'Move object here', tip: 'Move an object to you', fields: [{ key: 'g', label: 'Object GUID', placeholder: 'from Objects nearby' }], cmd: '.gobject move {g}' },
    { icon: '🔄', label: 'Turn object', tip: 'Face an object the way you face', fields: [{ key: 'g', label: 'Object GUID' }], cmd: '.gobject turn {g}' },
    { icon: '🗑', label: 'Delete object', tip: 'Remove an object for good', confirm: 'Delete this object permanently?', fields: [{ key: 'g', label: 'Object GUID' }], cmd: '.gobject delete {g}' },
  ]],
  ['Players', [
    { icon: 'ℹ', label: 'Player info', tip: 'Account, level, money, IP of a player', fields: [{ key: 'name', label: 'Player', value: 'target', optional: true }], cmd: '.pinfo {name}' },
    { icon: '💬', label: 'Message on screen', tip: 'Big on-screen message to one player', fields: [{ key: 'name', label: 'Player', value: 'target' }, { key: 't', label: 'Message' }], cmd: '.send message {name} {t}' },
    { icon: '✉', label: 'Send mail', tip: 'Mail a letter', fields: [{ key: 'name', label: 'Player', value: 'target' }, { key: 's', label: 'Subject' }, { key: 't', label: 'Text' }], cmd: '.send mail {name} "{s}" "{t}"' },
    { icon: '🎁', label: 'Mail items', tip: 'Mail items (ID or ID:count, separated by spaces)', find: 'item', fields: [{ key: 'name', label: 'Player', value: 'target' }, { key: 's', label: 'Subject', value: 'A gift' }, { key: 't', label: 'Text', value: 'Enjoy!' }, { key: 'items', label: 'Items', placeholder: '19019 17182:1' }], cmd: '.send items {name} "{s}" "{t}" {items}' },
    { icon: '💰', label: 'Mail gold', tip: 'Mail gold', fields: [{ key: 'name', label: 'Player', value: 'target' }, { key: 'g', label: 'Gold', value: '100', type: 'number' }], cmd: (v) => `.send money ${v.name} "Gold" "From the Game Masters" ${Math.round(Number(v.g) * 10000)}` },
    { icon: '🔇', label: 'Mute', tip: 'Stop a player from chatting', fields: [{ key: 'name', label: 'Player', value: 'target' }, { key: 'm', label: 'Minutes', value: '10' }], cmd: '.mute {name} {m}' },
    { icon: '🔊', label: 'Unmute', tip: 'Let a player chat again', fields: [{ key: 'name', label: 'Player', value: 'target' }], cmd: '.unmute {name}' },
    { icon: '👢', label: 'Kick', tip: 'Disconnect a player', confirm: 'Kick this player?', fields: [{ key: 'name', label: 'Player', value: 'target' }], cmd: '.kick {name}' },
    { icon: '⛔', label: 'Ban character', tip: 'Ban by character name', confirm: 'Ban this character?', fields: [{ key: 'name', label: 'Character', value: 'target' }, { key: 'time', label: 'Duration', value: '1d', placeholder: '1d, 2h30m, -1 = forever' }, { key: 'why', label: 'Reason', value: 'GM decision' }], cmd: '.ban character {name} {time} {why}' },
    { icon: '⛔', label: 'Ban account', tip: 'Ban a whole account', confirm: 'Ban this account?', fields: [{ key: 'name', label: 'Account', placeholder: 'account name' }, { key: 'time', label: 'Duration', value: '1d' }, { key: 'why', label: 'Reason', value: 'GM decision' }], cmd: '.ban account {name} {time} {why}' },
    { icon: '✅', label: 'Unban character', tip: 'Lift a character ban', fields: [{ key: 'name', label: 'Character' }], cmd: '.unban character {name}' },
    { icon: '✅', label: 'Unban account', tip: 'Lift an account ban', fields: [{ key: 'name', label: 'Account' }], cmd: '.unban account {name}' },
    { icon: '📜', label: 'Ban list', tip: 'Every banned character', cmd: '.banlist character' },
    { icon: '🛡', label: 'GMs online', tip: 'Game Masters in game right now', cmd: '.gm ingame' },
    { icon: '💾', label: 'Save everyone', tip: 'Save all online characters', cmd: '.saveall' },
  ]],
  ['Guilds & tickets', [
    { icon: '🏳', label: 'Create guild', tip: 'Make a guild with a leader', fields: [{ key: 'leader', label: 'Leader', value: 'player' }, { key: 'g', label: 'Guild name' }], cmd: '.guild create {leader} "{g}"' },
    { icon: '➕', label: 'Add to guild', tip: 'Put a player in a guild', fields: [{ key: 'name', label: 'Player', value: 'player' }, { key: 'g', label: 'Guild name' }], cmd: '.guild invite {name} "{g}"' },
    { icon: '➖', label: 'Remove from guild', tip: 'Take a player out of their guild', fields: [{ key: 'name', label: 'Player', value: 'target' }], cmd: '.guild uninvite {name}' },
    { icon: '🎖', label: 'Guild rank', tip: 'Set a member\'s rank (0 = leader)', fields: [{ key: 'name', label: 'Player', value: 'target' }, { key: 'r', label: 'Rank', value: '1' }], cmd: '.guild rank {name} {r}' },
    { icon: '🗑', label: 'Disband guild', tip: 'Delete a guild', confirm: 'Delete this guild?', fields: [{ key: 'g', label: 'Guild name' }], cmd: '.guild delete "{g}"' },
    { icon: '🎫', label: 'Open tickets', tip: 'The GM ticket queue', cmd: '.tickets list' },
    { icon: '📖', label: 'Read ticket', tip: 'Show a ticket', fields: [{ key: 'id', label: 'Ticket #' }], cmd: '.ticket read {id}' },
    { icon: '💬', label: 'Answer ticket', tip: 'Whisper the ticket\'s author', fields: [{ key: 'id', label: 'Ticket #' }, { key: 't', label: 'Message' }], cmd: '.ticket whisper {id} {t}' },
    { icon: '➜', label: 'Go to ticket', tip: 'Teleport to where the ticket was made', fields: [{ key: 'id', label: 'Ticket #' }], cmd: '.ticket go {id}' },
    { icon: '✔', label: 'Resolve ticket', tip: 'Close a ticket as solved', fields: [{ key: 'id', label: 'Ticket #' }, { key: 't', label: 'Note', optional: true }], cmd: '.ticket resolve {id} {t}' },
  ]],
  ['Server & world', [
    { icon: '📣', label: 'Announce', tip: 'Message to everyone in chat', fields: [{ key: 't', label: 'Message' }], cmd: '.announce {t}' },
    { icon: '🖥', label: 'Notify on screen', tip: 'Big on-screen message to everyone', fields: [{ key: 't', label: 'Message' }], cmd: '.notify {t}' },
    { icon: 'ℹ', label: 'Server info', tip: 'Version, uptime and players online', cmd: '.server info' },
    { icon: '📝', label: 'Set welcome message', tip: 'The message of the day', fields: [{ key: 't', label: 'Message of the day' }], cmd: '.server set motd {t}' },
    { icon: '🌦', label: 'Weather', tip: 'Change the weather here', fields: [{ key: 't', label: 'Weather', options: [['0', 'Clear'], ['1', 'Rain'], ['2', 'Snow'], ['3', 'Sandstorm']], value: '1' }, { key: 'i', label: 'Intensity (0 - 1)', value: '0.8' }], cmd: '.wchange {t} {i}' },
    { icon: '🎉', label: 'Active events', tip: 'World events running now', cmd: '.event list' },
    { icon: '▶', label: 'Start event', tip: 'Start a world event', find: 'event', fields: [{ key: 'id', label: 'Event ID' }], cmd: '.event start {id}' },
    { icon: '⏹', label: 'Stop event', tip: 'Stop a world event', fields: [{ key: 'id', label: 'Event ID' }], cmd: '.event stop {id}' },
    { icon: '⟳', label: 'Reload settings', tip: 'Reload mangosd.conf', cmd: '.reload config' },
    { icon: '⟳', label: 'Reload database', tip: 'Reload every reloadable table', confirm: 'Reload all database tables?', cmd: '.reload all' },
    { icon: '🔁', label: 'Restart server', tip: 'Restart after a countdown', confirm: 'Restart the server?', fields: [{ key: 's', label: 'Seconds', value: '60' }], cmd: '.server restart {s}' },
    { icon: '⏻', label: 'Shut down server', tip: 'Shut down after a countdown', confirm: 'Shut the server down?', fields: [{ key: 's', label: 'Seconds', value: '60' }], cmd: '.server shutdown {s}' },
    { icon: '✋', label: 'Cancel restart', tip: 'Stop a pending restart or shutdown', cmd: '.server shutdown cancel' },
  ]],
  ['Playerbots', [
    { icon: '🤖', label: 'Add bot', tip: 'Log in one of your account\'s characters as a bot', fields: [{ key: 'name', label: 'Character name' }], cmd: '.bot add {name}' },
    { icon: '✖', label: 'Remove bot', tip: 'Log a bot out', fields: [{ key: 'name', label: 'Bot name', value: 'target' }], cmd: '.bot remove {name}' },
    { icon: '🎲', label: 'Random bots', tip: 'Random bot control (e.g. stats, reload, init)', fields: [{ key: 'a', label: 'Option', value: 'stats' }], cmd: '.rndbot {a}' },
    { icon: '⌨', label: 'Bot command', tip: 'Any playerbot command', fields: [{ key: 'a', label: 'Command', placeholder: 'e.g. add Alice' }], cmd: '.bot {a}' },
  ]],
];

const CSS = `
#gmp .tools{display:flex;flex:1;min-height:0}
#gmp .tgroups{width:170px;border-right:1px solid #2c2923;padding:8px;display:flex;flex-direction:column;gap:5px;overflow:auto}
#gmp .tgroups button{text-align:left;padding:7px 10px}
#gmp .tgroups button.on{border-color:#ffe08a;color:#fff;background:linear-gradient(180deg,#c22f22,#7a140c 50%,#4e0905)}
#gmp .tbody{flex:1;display:flex;flex-direction:column;min-width:0}
#gmp .tsearch{padding:8px 10px;border-bottom:1px solid #2c2923;display:flex;gap:8px;align-items:center}
#gmp .tsearch input{flex:1}
#gmp .tgrid2{flex:1;overflow:auto;padding:10px;display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:8px;align-content:start}
#gmp .tool{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;min-height:64px;padding:8px 6px;white-space:normal;text-align:center;line-height:1.15}
#gmp .tool .ic{font-size:19px;line-height:1;filter:drop-shadow(1px 1px 0 #000)}
#gmp .tool .more{font-size:10px;color:#e6c46a;opacity:.8}
#gmp .tghead{grid-column:1/-1;font:bold 13px var(--wow);color:var(--gold);border-bottom:1px solid #2c2923;padding:6px 2px 3px;margin-top:4px}
`;

export default function (gm) {
  gm.css(CSS);
  const { esc, wenilla } = gm;
  const groups = GROUPS.map(([name, tools]) => ({ name, tools }));
  let current = gm.store.get('toolGroup', groups[0].name);
  let pane = null;

  gm.addTools = (name, tools) => {
    const g = groups.find((x) => x.name === name);
    if (g) g.tools.push(...tools);
    else groups.push({ name, tools });
    if (pane) render();
  };

  function fill(v) {
    const t = gm.target();
    const me = wenilla.state?.self?.name || '';
    if (v === 'target') return t?.name || '';
    if (v === 'player') return t?.isPlayer ? t.name : me;
    if (v === 'me') return me;
    return v ?? '';
  }

  function build(tool, values) {
    if (typeof tool.cmd === 'function') return tool.cmd(values, gm);
    if (Array.isArray(tool.cmd)) {
      const all = tool.cmd.map((c) => build({ ...tool, cmd: c }, values));
      return all.includes(null) ? null : all;
    }
    let missing = null;
    const out = tool.cmd.replace(/"?\{(\w+)\}"?/g, (whole, key) => {
      const f = tool.fields?.find((x) => x.key === key);
      const v = (values[key] ?? '').trim();
      if (!v) {
        if (f && !f.optional) missing = f.label;
        return '';
      }
      return whole.startsWith('"') ? `"${v.replace(/"/g, "'")}"` : v;
    });
    if (missing) {
      gm.log(`Fill in “${missing}”.`, 'err');
      return null;
    }
    return out.replace(/\s+/g, ' ').trim();
  }

  async function runTool(tool) {
    let values = {};
    if (tool.fields?.length) {
      values = await gm.prompt({
        title: tool.label,
        text: tool.tip + (tool.find ? ' (Look up IDs in the Loot tab.)' : ''),
        ok: tool.confirm ? 'Do it' : 'Accept',
        fields: tool.fields.map((f) => ({ ...f, value: fill(f.value) })),
      });
      if (!values) return;
    } else if (tool.confirm) {
      const ok = await gm.prompt({ title: tool.label, text: tool.confirm, ok: 'Yes' });
      if (!ok) return;
    }
    if (tool.confirm && tool.fields?.length) {
      const ok = await gm.prompt({ title: tool.label, text: tool.confirm, ok: 'Yes' });
      if (!ok) return;
    }
    const cmd = build(tool, values);
    if (!cmd) return;
    (Array.isArray(cmd) ? cmd : [cmd]).forEach((c, i) => setTimeout(() => gm.send(c), i * 300));
  }

  function toolButton(t, gi, ti) {
    return `<button class="tool" data-g="${gi}" data-t="${ti}" title="${esc(t.tip || '')}"><span class="ic">${t.icon || '•'}</span><span>${esc(t.label)}</span>${
      t.fields?.length ? '<span class="more">…</span>' : ''
    }</button>`;
  }

  function render() {
    const q = (pane.querySelector('[data-ref="tq"]')?.value || '').trim().toLowerCase();
    if (!groups.some((g) => g.name === current)) current = groups[0].name;
    let grid = '';
    if (q) {
      groups.forEach((g, gi) => {
        const hits = g.tools.map((t, ti) => [t, ti]).filter(([t]) => (t.label + ' ' + (t.tip || '')).toLowerCase().includes(q));
        if (hits.length) grid += `<div class="tghead">${esc(g.name)}</div>` + hits.map(([t, ti]) => toolButton(t, gi, ti)).join('');
      });
      if (!grid) grid = '<div class="empty" style="grid-column:1/-1">No tool matches. The Advanced tab has every raw command.</div>';
    } else {
      const gi = groups.findIndex((g) => g.name === current);
      grid = groups[gi].tools.map((t, ti) => toolButton(t, gi, ti)).join('');
    }
    const keepQ = q;
    pane.innerHTML = `<div class="tools">
      <div class="tgroups">${groups.map((g) => `<button class="${!q && g.name === current ? 'on' : ''}" data-group="${esc(g.name)}">${esc(g.name)}</button>`).join('')}</div>
      <div class="tbody">
        <div class="tsearch"><input data-ref="tq" placeholder="Find a tool… (e.g. spawn, ban, level, weather)" value="${esc(keepQ)}"><span class="hint">Most tools act on your target, else on you.</span></div>
        <div class="tgrid2">${grid}</div>
      </div></div>`;
    const inp = pane.querySelector('[data-ref="tq"]');
    if (keepQ) {
      inp.focus();
      inp.setSelectionRange(inp.value.length, inp.value.length);
    }
  }

  gm.addTab(
    'tools',
    'Tools',
    (p) => {
      if (pane !== p) {
        pane = p;
        p.style.padding = '0';
        p.addEventListener('click', (e) => {
          const g = e.target.closest('[data-group]');
          if (g) {
            current = g.dataset.group;
            gm.store.set('toolGroup', current);
            pane.querySelector('[data-ref="tq"]').value = '';
            return render();
          }
          const b = e.target.closest('[data-t]');
          if (b) runTool(groups[Number(b.dataset.g)].tools[Number(b.dataset.t)]);
        });
        p.addEventListener('input', (e) => {
          if (e.target.dataset.ref === 'tq') render();
        });
      }
      render();
    },
    { first: true },
  );
}
