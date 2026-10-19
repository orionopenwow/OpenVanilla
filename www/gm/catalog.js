// Open Vanilla GM panel: command catalog.
// Every chat command in the CMaNGOS Classic core this server runs (mangos-classic commit
// 5f8a6557, the hash in mangosd-startup.log), from src/game/Chat/Chat.cpp, with the security
// level each needs and the syntax/help text from the core's `command` table (sql/base/mangos.sql).
// Levels: 0 Player, 1 Moderator, 2 Game Master, 3 Administrator, 4 Console (console only).
// One command per line: name <TAB> level <TAB> syntax <TAB> description.
// Commands with no help text in the DB still work; "Server help" asks your server live.

export const CATALOG_SOURCE = 'cMaNGOS Classic 5f8a6557 (SPP Classics) + Playerbots';

export const CATALOG = `
account	0	.account	Display the access level of your account.
account characters	3	.account characters [#accountId|$accountName]	Show list all characters for account selected by provided #accountId or $accountName, or for selected player in game.
account create	4	.account create $account $password	Create account and set password to it.
account delete	4	.account delete $account	Delete account with all characters.
account onlinelist	4	.account onlinelist	Show list of online accounts.
account lock	0	.account lock [on|off]	Allow login from account only from current used IP or remove this requirement.
account set addon	3	.account set addon [#accountId|$accountName] #addon	Set user (possible targeted) expansion addon level allowed.
account set gmlevel	4	.account set gmlevel [#accountId|$accountName] #level	Set the security level for targeted player (can't be used at self) or for #accountId or $accountName to a level of #level.
account set password	4	.account set password (#accountId|$accountName) $password $password	Set password for account.
account set edition	3
account password	0	.account password $old_password $new_password $new_password	Change your account password.
auction	3	.auction	Show your team auction store.
auction alliance	3	.auction alliance	Show alliance auction store independent from your team.
auction goblin	3	.auction goblin	Show goblin auction store common for all teams.
auction horde	3	.auction horde	Show horde auction store independent from your team.
auction item	3	.auction item (alliance|horde|goblin) #itemid[:#itemcount] [[[#minbid] #buyout] [short|long|verylong]	Add new item to an specific auction house at short|long|verylong periods.
ahbot	2		Auction house bot.
ahbot rebuild	3
ahbot reload	3
ahbot status	3
ahbot item	3
rndbot	2		Random playerbots control (Playerbots module).
bot	0		Playerbot control: .bot add/remove/login/logout <name>, see .help bot (Playerbots module).
cast	3	.cast #spellid [triggered]	Cast #spellid to selected target.
cast back	3	.cast back #spellid [triggered]	Selected target will cast #spellid to your character.
cast dist	3	.cast dist #spellid [#dist [triggered]]	You will cast spell to pint at distance #dist.
cast self	3	.cast self #spellid [triggered]	Cast #spellid by target at target itself.
cast target	3	.cast target #spellid [triggered]	Selected target will cast #spellid to his victim.
character deleted delete	4	.character deleted delete #guid|$name	Completely deletes the selected characters.
character deleted list	4	.character deleted list [#guid|$name]	Shows a list with all deleted characters.
character deleted restore	3	.character deleted restore #guid|$name [$newname] [#new account]	Restores deleted characters.
character deleted old	4	.character deleted old [#keepDays]	Completely deletes all characters with deleted time longer #keepDays.
character erase	4	.character erase $name	Delete character $name.
character level	3	.character level [$playername] [#level]	Set the level of character with $playername (or the selected if not name provided) by #numberoflevels Or +1 if no #numberoflevels provided).
character rename	2	.character rename [$name]	Mark selected in game or by $name in command character for rename at next login.
character reputation	2	.character reputation [$player_name]	Show reputation information for selected player or player find by $player_name.
character citytitle	3
channel list	1	.channel list [#max] [static]	Show list of custom channels with amounts of players joined.
channel static	1	.channel static $channelname on|off	Enable or disable static mode for a custom channel with name $channelname.
debug anim	2	.debug anim #emoteid	Play emote #emoteid for your character.
debug areatriggers	1
debug bg	3	.debug bg	Toggle debug mode for battlegrounds.
debug getitemstate	3
debug lootrecipient	2
debug listupdatefields	3
debug getitemvalue	3	.debug getitemvalue #itemguid #field [int|hex|bit|float]	Get the field #field of the item #itemguid in your inventroy.
debug getvaluebyindex	3
debug getvaluebyname	3
debug moditemvalue	3	.debug moditemvalue #guid #field [int|float| &= | |= | &=~ ] #value	Modify the field #field of the item #itemguid in your inventroy by value #value.
debug modvalue	3	.debug modvalue #field [int|float| &= | |= | &=~ ] #value	Modify the field #field of the selected target by value #value.
debug play cinematic	1	.debug play cinematic #cinematicid	Play cinematic #cinematicid for you.
debug play sound	1	.debug play sound #soundid	Play sound with #soundid.
debug play music	1
debug play petdismiss	1
debug send buyerror	3
debug send channelnotify	3
debug send chatmmessage	3
debug send equiperror	3
debug send opcode	3
debug send poi	3
debug send qfailedresult	3
debug send qpartymsg	3
debug send qinvalidmsg	3
debug send sellerror	3
debug send spellfail	3
debug send spellVisual	3
debug send worldstate	3
debug setaurastate	3
debug setitemvalue	3	.debug setitemvalue #guid #field [int|hex|bit|float] #value	Set the field #field of the item #itemguid in your inventroy to value #value.
debug script help	2
debug script command	2
debug setvaluebyindex	3
debug setvaluebyname	3
debug spellcheck	4
debug spellcoefs	3	.debug spellcoefs #spellid	Show default calculated and DB stored coefficients for direct/dot heal/damage.
debug spellmods	3	.debug spellmods (flat|pct) #spellMaskBitIndex #spellModOp #value	Set at client side spellmod affect for spell that have bit set with index #spellMaskBitIndex in spell family mask for values dependent from spellmod #spellModOp to #value.
debug taxi	3	.debug taxi	Toggle debug mode for taxi flights.
debug uws	3
debug waypoint	3
debug byte	3
debug moveflag	3
debug visibility atclient	1
debug visibility isvisible	1
debug perf tempspawn	3
debug perf gridsloaded	3
debug utf8overflow	3
debug chatfreeze	3
debug opcodeouthistory	3
debug opcodeinchistory	3
debug transports	3
debug spawn list	2
debug spawn respawn	2
debug debugflags	3
debug packetlog	3
debug dbscript	3		Starts dbscript type param0 id param1 from player(source) to selected(target).
debug dbscripttargeted	3		Starts dbscript type param0 id param1 from selected(source) to param2 dbguid(target creature).
debug dbscriptsourced	3		Starts dbscript type param0 id param1 from param2 dbguid(source creature) to selected(target).
debug dbscriptguided	3		Starts dbscript type param0 id param1 from param2 dbguid(source creature) to param3 dbguid(target creature).
event	2	.event #event_id	Show details about event with #event_id.
event list	2	.event list	Show list of currently active events.
event start	2	.event start #event_id	Start event #event_id.
event stop	2	.event stop #event_id	Stop event #event_id.
gm	3	.gm [on/off]	Enable or Disable in game GM MODE or show current state of on/off not provided.
gm chat	3	.gm chat [on/off]	Enable or disable chat GM MODE (show gm badge in messages) or show current state of on/off not provided.
gm fly	3	.gm fly [on/off]	Enable/disable gm fly mode.
gm unkillable	3	.gm unkillable [on/off]	Toggle taking no damage.
gm ingame	3	.gm ingame	Display a list of available in game Game Masters.
gm list	3	.gm list	Display a list of all Game Masters accounts and security levels.
gm mountup	3	.gm mountup [fast|slow|#displayid|target]	If #displayid is provided, visually mounts your character on a provided creature likeness.
gm visible	3	.gm visible on/off	Output current visibility state or make GM visible(on) and invisible(off) for other players.
gm setview	3	.gm setview	Set farsight view on selected unit.
honor add	2	.honor add $amount	Add a certain amount of honor (gained in lifetime) to the selected player.
honor addkill	2	.honor addkill	Add the targeted unit as one of your pvp kills today (you only get honor if it's a racial leader or a player)
honor show	2	.honor show	Display the honor stats of the selected player
honor update	2	.honor update	Force honor to be update
go	1	.go [$playername|pointlink|#x #y #z [#mapid]]	Teleport your character to point with coordinates of player $playername, or coordinates of one from shift-link types: player, tele, taxinode, creature/creature_entry, gameobject/gameobject_entry.
go creature	1	.go creature (#creature_guid|$creature_name|id #creature_id)	Teleport your character to creature with guid #creature_guid, or with name including $creature_name, or to a creature with template id #creature_id.
go graveyard	1	.go graveyard #graveyardId	Teleport to graveyard with the graveyardId specified.
go grid	1	.go grid #gridX #gridY [#mapId]	Teleport the gm to center of grid with provided indexes at map #mapId (or current map if it not provided).
go object	1	.go object (#gameobject_guid|$gameobject_name|id #gameobject_id)	Teleport your character to gameobject with guid #gameobject_guid, or with name including $gameobject_name, or to a gameobject with template id #gameobject_id.
go taxinode	1	.go taxinode #taxinode	Teleport player to taxinode coordinates.
go trigger	1	.go trigger (#trigger_id|$trigger_shift-link|$trigger_target_shift-link) [target]	Teleport your character to areatrigger with id #trigger_id or trigger id associated with shift-link.
go warp	1
go zonexy	1	.go zonexy #x #y [#zone]	Teleport player to point with (#x,#y) client coordinates at ground(water) level in zone #zoneid or current zone if #zoneid not provided.
go xy	1	.go xy #x #y [#mapid]	Teleport player to point with (#x,#y) coordinates at ground(water) level at map #mapid or same map if #mapid not provided.
go xyz	1	.go xyz #x #y #z [#mapid]	Teleport player to point with (#x,#y,#z) coordinates at map #mapid or same map if #mapid not provided.
go next	3
gobject add	2	.gobject add #id <spawntimeSecs>	Add a game object from game object templates to the world at your current location using the #id.
gobject delete	2	.gobject delete #go_guid	Delete gameobject with guid #go_guid.
gobject move	2	.gobject move #goguid [#x #y #z]	Move gameobject #goguid to character coordinates (or to (#x,#y,#z) coordinates if its provide).
gobject near	2	.gobject near [#distance]	Output gameobjects at distance #distance from player.
gobject nearspawned	2
gobject target	2	.gobject target [#go_id|#go_name_part]	Locate and show position nearest gameobject.
gobject turn	2	.gobject turn #goguid	Set for gameobject #goguid orientation same as current character orientation.
gobject activate	2
gobject despawn	2
gobject respawn	2
guild create	2	.guild create [$GuildLeaderName] "$GuildName"	Create a guild named $GuildName with the player $GuildLeaderName (or selected) as leader.
guild delete	2	.guild delete "$GuildName"	Delete guild $GuildName.
guild invite	2	.guild invite [$CharacterName] "$GuildName"	Add player $CharacterName (or selected) into a guild $GuildName.
guild uninvite	2	.guild uninvite [$CharacterName]	Remove player $CharacterName (or selected) from a guild.
guild rank	2	.guild rank $CharacterName #Rank	Set for $CharacterName rank #Rank in a guild.
instance listbinds	3	.instance listbinds	Lists the binds of the selected player.
instance unbind	3	.instance unbind all	All of the selected player's binds will be cleared.
instance stats	3	.instance stats	Shows statistics about instances.
instance savedata	3	.instance savedata	Save the InstanceData for the current player's map to the DB.
learn	3	.learn #spell [all]	Selected character learn a spell of id #spell.
learn all	3	.learn all	Learn all big set different spell maybe useful for Administaror.
learn all_gm	2	.learn all_gm	Learn all default spells for Game Masters.
learn all_crafts	2	.learn all_crafts	Learn all professions and recipes.
learn all_default	1	.learn all_default [$playername]	Learn for selected/$playername player all default spells for his race/class and spells rewarded by completed quests.
learn all_lang	1	.learn all_lang	Learn all languages
learn all_myclass	3	.learn all_myclass	Learn all spells and talents available for his class.
learn all_myspells	3	.learn all_myspells	Learn all spells (except talents and spells with first rank learned as talent) available for his class.
learn all_mytalents	3	.learn all_mytalents	Learn all talents (and spells with first rank learned as talent) available for his class.
learn all_mylevel	3
learn all_recipes	2	.learn all_recipes [$profession]	Learns all recipes of specified profession and sets skill level to max. Example: .learn all_recipes enchanting
link add	3
link remove	3
link edit	3
link toggle	3
link check	3
list areatriggers	3
list auras	3
list creature	3	.list creature #creature_id [#max_count]	Output creatures with creature id #creature_id found in world.
list item	3	.list item #item_id [#max_count]	Output items with item id #item_id found in all character inventories, mails, auctions, and guild banks.
list object	3
list talents	3	.list talents	Show list all really known (as learned spells) talent rank spells for selected player or self.
lookup account email	2	.lookup account email $emailpart [#limit]	Searchs accounts, which email including $emailpart with optional parametr #limit of results.
lookup account ip	2	.lookup account ip $ippart [#limit]	Searchs accounts, which last used ip inluding $ippart (textual) with optional parametr #$limit of results.
lookup account name	2	.lookup account name $accountpart [#limit]	Searchs accounts, which username including $accountpart with optional parametr #limit of results.
lookup area	1	.lookup area $namepart	Looks up an area by $namepart, and returns all matches with their area ID's.
lookup creature	3	.lookup creature $namepart	Looks up a creature by $namepart, and returns all matches with their creature ID's.
lookup event	2	.lookup event $name	Attempts to find the ID of the event with the provided $name.
lookup faction	3	.lookup faction $name	Attempts to find the ID of the faction with the provided $name.
lookup item	3	.lookup item $itemname	Looks up an item by $itemname, and returns all matches with their Item ID's.
lookup itemset	3	.lookup itemset $itemname	Looks up an item set by $itemname, and returns all matches with their Item set ID's.
lookup object	3	.lookup object $objname	Looks up an gameobject by $objname, and returns all matches with their Gameobject ID's.
lookup quest	3	.lookup quest $namepart	Looks up a quest by $namepart, and returns all matches with their quest ID's.
lookup player account	2	.lookup player account $accountpart [#limit]	Searchs players, which account username including $accountpart with optional parametr #limit of results.
lookup player email	2	.lookup player email $emailpart [#limit]	Searchs players, which account email including $emailpart with optional parametr #limit of results.
lookup player ip	2	.lookup player ip $ippart [#limit]	Searchs players, which account last used ip inluding $ippart (textual) with optional parametr #limit of results.
lookup pool	2	.lookup pool $pooldescpart	List of pools (anywhere) with substring in description.
lookup skill	3	.lookup skill $namepart	Looks up a skill by $namepart, and returns all matches with their skill ID's.
lookup spell	3	.lookup spell $namepart	Looks up a spell by $namepart, and returns all matches with their spell ID's.
lookup taxinode	3	.lookup taxinode $substring	Search and output all taxinodes with provide $substring in name.
lookup tele	1	.lookup tele $substring	Search and output all .tele command locations with provide $substring in name.
modify hp	1	.modify hp #newhp	Modify the hp of the selected player.
modify mana	1	.modify mana #newmana	Modify the mana of the selected player.
modify rage	1	.modify rage #newrage	Modify the rage of the selected player.
modify energy	1	.modify energy #energy	Modify the energy of the selected player.
modify money	1	.modify money #money	Add or remove money (in copper; negative removes) to the selected player.
modify speed	1	.modify speed #rate	Modify the running speed of the selected player to "normal base run speed"*rate.
modify swim	1	.modify swim #rate	Modify the swim speed of the selected player to "normal swim speed"*rate.
modify scale	1	.modify scale #scale	Change model scale for targeted player (util relogin) or creature (until respawn).
modify bwalk	1	.modify bwalk #rate	Modify the speed of the selected player while running backwards to "normal walk back speed"*rate.
modify aspeed	1	.modify aspeed #rate	Modify all speeds -run,swim,run back,swim back- of the selected player to "normalbase speed for this move type"*rate.
modify faction	1	.modify faction #factionid #flagid #npcflagid #dynamicflagid	Modify the faction and flags of the selected creature.
modify tp	1	.modify tp #points	Set unspent talent points.
modify mount	1	.modify mount [fast|slow]	Provide selected player a random unusual land mount.
modify honor	1	.modify honor $field $value	Add $value to an honor $field (debug only, not saved). Fields: points / rank / todaykills / yesterdaykills / yesterdayhonor / thisweekkills / thisweekhonor...
modify rep	2	.modify rep #repId (#repvalue | $rankname [#delta])	Sets the selected players reputation with faction #repId to #repvalue or to $reprank.
modify drunk	1	.modify drunk #value	Set drunk level to #value (0..100).
modify standstate	2	.modify standstate #emoteid	Change the emote of your character while standing to #emoteid.
modify morph	2	.modify morph #displayid	Change your current model id to #displayid.
modify gender	2	.modify gender male/female	Change gender of selected player.
modify strength	3	.modify strength #value
modify agility	3	.modify agility #value
modify stamina	3	.modify stamina #value
modify intellect	3	.modify intellect #value
modify spirit	3	.modify spirit #value
modify armor	3	.modify armor #value
modify holyresist	3	.modify holyresist #value
modify fireresist	3	.modify fireresist #value
modify natureresist	3	.modify natureresist #value
modify frostresist	3	.modify frostresist #value
modify shadowresist	3	.modify shadowresist #value
modify arcaneresist	3	.modify arcaneresist #value
modify ap	3	.modify ap #value
modify rangeap	3	.modify rangeap #value
modify spellpower	3	.modify spellpower #value
modify crit	3	.modify crit #value
modify spellcrit	3	.modify spellcrit #value
modify meleehaste	3	.modify meleehaste #value
modify rangehaste	3	.modify rangehaste #value
modify spellhaste	3	.modify spellhaste #value
modify block	3	.modify block #value
modify dodge	3	.modify dodge #value
modify parry	3	.modify parry #value
npc add	2	.npc add #creatureid	Spawn a creature by the given template id of #creatureid.
npc additem	2	.npc additem #itemId [#maxcount] [#incrtime]	Add item #itemid to item list of selected vendor.
npc aiinfo	2	.npc aiinfo	Show npc AI and script information.
npc allowmove	3	.npc allowmove	Enable or disable movement creatures in world.
npc changeentry	3
npc changelevel	2	.npc changelevel #level	Change the level of the selected creature to #level.
npc delete	2	.npc delete [#guid]	Delete creature with guid #guid (or the selected if no guid is provided)
npc delitem	2	.npc delitem #itemId	Remove item #itemid from item list of selected vendor.
npc factionid	2	.npc factionid #factionid	Set the faction of the selected creature to #factionid.
npc flag	2	.npc flag #npcflag	Set the NPC flags of creature template of the selected creature and selected creature to #npcflag.
npc follow	2	.npc follow	Selected creature start follow you until death/fight/etc.
npc info	3	.npc info	Display a list of details for the selected creature.
npc threat	3
npc move	2	.npc move [#creature_guid]	Move the targeted creature spawn point to your coordinates.
npc playemote	3	.npc playemote #emoteid	Make the selected creature emote with an emote of id #emoteid.
npc setmodel	2	.npc setmodel #displayid	Change the model id of the selected creature to #displayid.
npc setmovetype	2	.npc setmovetype [#creature_guid] stay/random/way [NODEL]	Set for creature pointed by #creature_guid (or selected if #creature_guid not provided) movement type and move it to respawn position (if creature alive).
npc spawndist	2	.npc spawndist #dist	Adjust spawndistance of selected creature to dist.
npc spawntime	2	.npc spawntime #time	Adjust spawntime of selected creature to time.
npc say	1	.npc say #text	Make the selected npc says #text.
npc spelllist	2
npc textemote	1	.npc textemote #emoteid	Make the selected creature to do textemote with an emote of id #emoteid.
npc unfollow	2	.npc unfollow	Selected creature (non pet) stop follow you.
npc whisper	1	.npc whisper #playerguid #text	Make the selected npc whisper #text to #playerguid.
npc yell	1	.npc yell #text	Make the selected npc yells #text.
npc tame	2	.npc tame	Tame selected creature (tameable non pet creature).
npc showloot	2
npc tempspawn	2
npc evade	2
npc despawn	2
npc formation info	2
npc formation reset	2
npc formation switch	2
npc group info	2
npc addweapon	3		Not yet implemented.
npc name	2	.npc name $name	Change the name of the selected creature or character to $name.
npc subname	2	.npc subname $Name	Change the subname of the selected creature or player to $Name.
pet levelloyalty	2
pool	2	.pool #pool_id	Pool information and full list creatures/gameobjects included in pool.
pool list	2	.pool list	List of pools with spawn in current map (only work in instances).
pool spawns	2	.pool spawns #pool_id	List current creatures/objects listed in pools (or in specific #pool_id) and spawned.
pdump load	3	.pdump load $filename $account [$newname] [$newguid]	Load character dump from dump file into character list of $account with saved or $newname, with saved (or first free) or $newguid guid.
pdump write	3	.pdump write $filename $playerNameOrGUID	Write character dump with name/guid $playerNameOrGUID to file $filename.
quest add	3	.quest add #quest_id	Add to character quest log quest #quest_id.
quest complete	3	.quest complete #questid	Mark all quest objectives as completed for target character active quest.
quest remove	3	.quest remove #quest_id	Set quest #quest_id state to not completed and not active (and remove from active quest list) for selected player.
reload all	3	.reload all	Reload all tables with reload support added and that can be _safe_ reloaded.
reload all_area	3	.reload all_area	Reload all 'areatrigger_*' tables if reload support added for this table and this table can be _safe_ reloaded.
reload all_eventai	3	.reload all_eventai	Reload 'creature_ai_*' tables if reload support added for these tables and these tables can be _safe_ reloaded.
reload all_gossips	3
reload all_item	3	.reload all_item	Reload 'item_required_target', 'page_texts' and 'item_enchantment_template' tables.
reload all_locales	3	.reload all_locales	Reload all 'locales_*' tables with reload support added and that can be _safe_ reloaded.
reload all_loot	3	.reload all_loot	Reload all '*_loot_template' tables.
reload all_npc	3	.reload all_npc	Reload 'points_of_interest' and 'npc_*' tables if reload support added for these tables and these tables can be _safe_ reloaded.
reload all_quest	3	.reload all_quest	Reload all quest related tables if reload support added for this table and this table can be _safe_ reloaded.
reload all_scripts	3	.reload all_scripts	Reload 'dbscripts_on_*' tables.
reload all_spell	3	.reload all_spell	Reload all 'spell_*' tables with reload support added and that can be _safe_ reloaded.
reload config	3	.reload config	Reload config settings (by default stored in mangosd.conf).
reload areatrigger_involvedrelation	3
reload areatrigger_tavern	3
reload areatrigger_teleport	3
reload command	3
reload conditions	3
reload creature_ai_scripts	3
reload creature_ai_summons	3
reload creature_battleground	3
reload creature_cooldowns	3
reload creature_involvedrelation	3
reload creature_loot_template	3
reload creature_spell_list	3
reload creature_questrelation	3
reload creature_template_classlevelstats	3
reload dbscripts_on_creature_death	3
reload dbscripts_on_event	3
reload dbscripts_on_gossip	3
reload dbscripts_on_go_use	3
reload dbscripts_on_quest_end	3
reload dbscripts_on_quest_start	3
reload dbscripts_on_spell	3
reload dbscripts_on_relay	3
reload disenchant_loot_template	3
reload fishing_loot_template	3
reload game_graveyard_zone	3
reload game_tele	3
reload gameobject_involvedrelation	3
reload gameobject_loot_template	3
reload gameobject_questrelation	3
reload gameobject_battleground	3
reload gossip_menu	3
reload gossip_menu_option	3
reload item_enchantment_template	3
reload item_loot_template	3
reload item_required_target	3
reload locales_creature	3
reload locales_gameobject	3
reload locales_gossip_menu_option	3
reload locales_item	3
reload locales_npc_text	3
reload locales_page_text	3
reload locales_points_of_interest	3
reload locales_quest	3
reload locales_questgiver_greeting	3
reload locales_trainer_greeting	3
reload locales_areatrigger_teleport	3
reload mail_loot_template	3
reload mangos_string	3
reload npc_gossip	3
reload npc_text	3
reload npc_trainer	3
reload npc_vendor	3
reload page_text	3
reload pickpocketing_loot_template	3
reload points_of_interest	3
reload questgiver_greeting	3
reload quest_template	3
reload reference_loot_template	3
reload reserved_name	3
reload reputation_reward_rate	3
reload reputation_spillover_template	3
reload skill_fishing_base_level	3
reload spawn_group	3
reload skinning_loot_template	3
reload spam_records	3
reload spell_affect	3
reload spell_area	3
reload spell_chain	3
reload spell_elixir	3
reload spell_learn_spell	3
reload spell_pet_auras	3
reload spell_proc_event	3
reload spell_proc_item_enchant	3
reload spell_script_target	3
reload spell_target_position	3
reload spell_threats	3
reload string_id	3
reload taxi_shortcuts	3
reload trainer_greeting	3
reset honor	3	.reset honor [Playername]	Reset all honor data for targeted character.
reset level	3	.reset level [Playername]	Reset level to 1 including reset stats and talents.
reset spells	3	.reset spells [Playername]	Removes all non-original spells from spellbook.
reset stats	3	.reset stats [Playername]	Resets(recalculate) all stats of the targeted player to their original values at current level.
reset talents	3	.reset talents [Playername]	Removes all talents of the targeted player.
reset taxinodes	3
reset mods	3
reset all	3	.reset all spells|talents	Request reset spells or talents at next login each existed character.
server corpses	2	.server corpses	Triggering corpses expire check in world.
server exit	4	.server exit	Terminate mangosd NOW.
server idlerestart	3	.server idlerestart #delay	Restart the server after #delay seconds if no active connections are present (no players).
server idlerestart cancel	3	.server idlerestart cancel	Cancel the restart/shutdown timer if any.
server idleshutdown	3	.server idleshutdown #delay [#exist_code]	Shut the server down after #delay seconds if no active connections are present (no players).
server idleshutdown cancel	3	.server idleshutdown cancel	Cancel the restart/shutdown timer if any.
server info	0	.server info	Display server version and the number of connected players.
server log filter	4	.server log filter [($filtername|all) (on|off)]	Show or set server log filters.
server log level	4	.server log level [#level]	Show or set server log level (0 - errors only, 1 - basic, 2 - detail, 3 - debug).
server motd	0	.server motd	Show server Message of the day.
server plimit	3	.server plimit [#num|-1|-2|-3|reset|player|moderator|gamemaster|administrator]	Without arg show current player amount and security level limitations for login to server, with arg set player limit or security limitation.
server resetallraid	3
server restart	3	.server restart #delay	Restart the server after #delay seconds.
server restart cancel	3	.server restart cancel	Cancel the restart/shutdown timer if any.
server shutdown	3	.server shutdown #delay [#exit_code]	Shut the server down after #delay seconds.
server shutdown cancel	3	.server shutdown cancel	Cancel the restart/shutdown timer if any.
server set motd	3	.server set motd $MOTD	Set server Message of the day.
tele	1	.tele #location	Teleport player to a given location.
tele add	3	.tele add $name	Add current your position to .tele command target locations list with name $name.
tele del	3	.tele del $name	Remove location with name $name for .tele command locations list.
tele name	1	.tele name [#playername] #location	Teleport the given character to a given location.
tele group	1	.tele group #location	Teleport a selected player and his group members to a given location.
trigger	2	.trigger [#trigger_id|$trigger_shift-link|$trigger_target_shift-link]	Show detail infor about areatrigger with id #trigger_id or trigger id associated with shift-link.
trigger active	2	.trigger active	Show list of areatriggers with activation zone including current character position.
trigger near	2	.trigger near [#distance]	Output areatriggers at distance #distance from player.
wp show	2	.wp show command [dbGuid] [pathId [wpOrigin]]	Command can be: on (show all related wp), first, last, off (hide all), info.
wp add	2	.wp add [Selected Creature or dbGuid] [pathId [wpOrigin]]
wp modify	2	.wp modify command [dbGuid, id] [value]	Command must be one of: waittime | scriptid | orientation | del | move. If no waypoint was selected, one can be chosen with dbGuid and id.
wp export	3	.wp export [#creature_guid or Select a Creature] $filename
bg start	2
bg stop	2
aura	3	.aura #spellid	Add the aura from spell #spellid to the selected Unit.
unaura	3	.unaura #spellid	Remove aura due to spell #spellid from the selected Unit.
announce	1	.announce $MessageToBroadcast	Send a global message to all players online in chat log.
notify	1	.notify $MessageToBroadcast	Send a global message to all players online in screen.
goname	1	.goname [$charactername]	Teleport to the given character.
appear	1	.appear [$charactername]	Teleport to the given character.
namego	1	.namego [$charactername]	Teleport the given character to you.
summon	1	.summon [$charactername]	Teleport the given character to you.
groupgo	1	.groupgo [$charactername]	Teleport the given character and his group to you.
commands	0	.commands	Display a list of available commands for your account level.
demorph	2	.demorph	Demorph the selected player.
die	3	.die	Kill the selected player.
revive	3	.revive	Revive the selected player.
dismount	0	.dismount	Dismount you, if you are mounted.
gps	1	.gps [$name|$shift-link]	Display the position information for a selected character or creature (or named player, or the creature/gameobject pointed to by a shift-link).
guid	2	.guid	Display the GUID for the selected character.
help	0	.help [$command]	Display usage instructions for the given $command.
itemmove	2	.itemmove #sourceslotid #destinationslotid	Move an item from slots #sourceslotid to #destinationslotid in your inventory. Not yet implemented.
cooldown list	3	.cooldown list	Active cooldown from selected unit.
cooldown clear	3	.cooldown clear [#spellid]	Remove cooldown from selected unit.
cooldown clearclientside	3	.cooldown clearclientside	Clear all cooldown client side only.
unlearn	3	.unlearn #spell [all]	Unlearn for selected player a spell #spell.
distance	3	.distance [$name/$link]	Display the distance from your character to the selected creature/player, or player with name $name, or the object a shift-link points to.
los	3
recall	1	.recall [$playername]	Teleport $playername or selected player to the place where he has been before last use of a teleportation command.
save	0	.save	Saves your character.
saveall	1	.saveall	Save all characters in game.
kick	2	.kick [$charactername]	Kick the given character name from the world.
ban account	3	.ban account $Name $bantime $reason	Ban account kick player.
ban character	3	.ban character $Name $bantime $reason	Ban account and kick player.
ban ip	3	.ban ip $Ip $bantime $reason	Ban IP.
ban note	3
ban warn	3
unban account	3	.unban account $Name	Unban accounts for account name pattern.
unban character	3	.unban character $Name	Unban accounts for character name pattern.
unban ip	3	.unban ip $Ip	Unban accounts for IP pattern.
baninfo account	3	.baninfo account $accountid	Watch full information about a specific ban.
baninfo character	3	.baninfo character $charactername	Watch full information about a specific ban.
baninfo ip	3	.baninfo ip $ip	Watch full information about a specific ban.
banlist account	3	.banlist account [$Name]	Searches the banlist for a account name pattern or show full list account bans.
banlist character	3	.banlist character $Name	Searches the banlist for a character name pattern.
banlist ip	3	.banlist ip [$Ip]	Searches the banlist for a IP pattern or show full list of IP bans.
start	0	.start	Teleport you to the starting area of your character.
taxicheat	1	.taxicheat on/off	Temporary grant access or remove to all taxi routes for the selected character.
linkgrave	3	.linkgrave #graveyard_id [alliance|horde]	Link current zone to graveyard for any (or alliance/horde faction ghosts).
neargrave	3	.neargrave [alliance|horde]	Find nearest graveyard linked to zone (or only nearest from accepts alliance or horde faction ghosts).
explorecheat	3	.explorecheat #flag	Reveal or hide all maps for the selected player.
levelup	3	.levelup [$playername] [#numberoflevels]	Increase/decrease the level of character with $playername (or the selected if not name provided) by #numberoflevels Or +1 if no #numberoflevels provided).
showarea	3	.showarea #areaid	Reveal the area of #areaid to the selected character.
hidearea	3	.hidearea #areaid	Hide the area of #areaid to the selected character.
additem	3	.additem #itemid/[#itemname]/#shift-click-item-link #itemcount	Adds the specified number of items of id #itemid (or exact name in brackets, or shift-click link) to your or selected character inventory.
additemset	3	.additemset #itemsetid	Add items from itemset of id #itemsetid to your or selected character inventory.
bank	3	.bank	Show your bank inventory.
wchange	3	.wchange #weathertype #status	Set current weather to #weathertype with an intensity of #status.
testing bags	2
ticket	2	.ticket #id	Acts as an alias of: ".ticket read"
ticket discard	2	.ticket discard #id [$conclusion]	Close GM ticket with number #id as discarded.
ticket escalate	2	.ticket escalate #id	Attempt to escalate GM ticket with number #id.
ticket go	2	.ticket go #id	Attempt to teleport to the location where GM ticket with number #id was originally created.
ticket goname	2	.ticket goname #id	Attempt to teleport to the author of the GM ticket with number #id.
ticket note	2	.ticket note #id $message	Add a note visible only to GMs to the GM ticket with number #id.
ticket read	2	.ticket read #id	Show contents of GM ticket with number #id.
ticket resolve	2	.ticket resolve #id [$conclusion]	Close GM ticket with number #id as resolved.
ticket sort	2	.ticket sort #id #categoryid	Attempt to assign the GM ticket with number #id with a category by id #categoryid.
ticket whisper	2	.ticket whisper #id $message	Attempt to answer in-game GM ticket with number #id by sending whisper with $message.
tickets	2	.tickets [on|off|[#categoryid #max|#max] [online]]	If "on"/"off" provided, enable or disable in-game GM ticket queue notifications and GM ticket alerts.
tickets list	2	.tickets list [#categoryid #max|#max] [online]	Show current GM tickets queue.
tickets queue	3	.tickets queue on|off	Enable or disable GM tickets queue until next restart or administrator's command.
maxskill	3	.maxskill	Sets all skills of the targeted player to their maximum values for its current level.
setskill	3	.setskill #skill #level [#max]	Set a skill of id #skill with a current skill value of #level and a maximum value of #max (or equal current maximum if not provide) for the selected character.
whispers	1	.whispers on|off	Enable/disable accepting whispers by GM from players.
wr	0
pinfo	2	.pinfo [$player_name]	Output account information for selected player or player find by $player_name.
respawn	3	.respawn	Respawn selected creature or respawn all nearest creatures (if none selected) and GO without waiting respawn time expiration.
send mass items	3	.send mass items #racemask|$racename|alliance|horde|all "#subject" "#text" itemid1[:count1] itemid2[:count2] ... itemidN[:countN]	Send a mail to players.
send mass mail	3	.send mass mail #racemask|$racename|alliance|horde|all "#subject" "#text"	Send a mail to players.
send mass money	3	.send mass money #racemask|$racename|alliance|horde|all "#subject" "#text" #money	Send mail with money to players.
send items	3	.send items #playername "#subject" "#text" itemid1[:count1] itemid2[:count2] ... itemidN[:countN]	Send a mail to a player.
send mail	1	.send mail #playername "#subject" "#text"	Send a mail to a player.
send message	3	.send message $playername $message	Send screen message to player from ADMINISTRATOR.
send money	3	.send money #playername "#subject" "#text" #money	Send mail with money to a player.
loadscripts	3	.loadscripts $scriptlibraryname	Unload current and load the script library $scriptlibraryname or reload current if $scriptlibraryname omitted.
mute	1	.mute [$playerName] $timeInMinutes	Disable chat messaging for any character from account of character $playerName (or currently selected) at $timeInMinutes minutes.
unmute	1	.unmute $playerName	Restore chat messaging for any character from account of character $playerName.
movement movegens	2	.movement movegens	Show movement generators stack for selected creature or player.
movement cometome	3	.movement cometome	Move selected creature to you.
movement movespeed	2	.movement movespeed	Show speed of selected creature.
movement debug	3
movement print	3
damage	3	.damage $damage_amount [$school [$spellid]]	Apply $damage to target.
combat stop	2	.combat stop [$playername]	Stop combat for selected character.
combat list	0
repairitems	2	.repairitems	Repair all selected player's items.
stable	3	.stable	Show your pet stable.
waterwalk	2	.waterwalk on/off	Set on/off waterwalk state for selected player.
quit	4	quit	Close RA connection.
mmap	3
mmap path	2
mmap loc	2
mmap loadedtiles	2
mmap stats	2
mmap testarea	2
mmap testheight	2
mmap demoapp	2
worldstate wareffort show	3
worldstate wareffort phase	3
worldstate wareffort gate	3
worldstate wareffort counter	3
worldstate scourgeinvasion show	3
worldstate scourgeinvasion state	3
worldstate scourgeinvasion battleswon	3
worldstate scourgeinvasion startzone	3
worldstate variables	3
worldstate set	3
loot stats	2
loot fullstats	2
`;
