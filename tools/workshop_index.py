#!/usr/bin/env python3
"""Open Vanilla Workshop indexer: refresh `workshop/catalog/*.yml` from where vanilla addons live.

    python3 tools/workshop_index.py                 seed list + our Classic+ addons + GitHub topics
    python3 tools/workshop_index.py --offline       no network: write/refresh entries, verify nothing
    python3 tools/workshop_index.py --only pfui,dpsmate
    python3 tools/workshop_index.py --catalog DIR   another catalogue folder (tests)

Sources, in order:
  1. SEED below: ~80 well-known vanilla 1.12 addons and the GitHub repositories they live in.
  2. Our own Classic+ addons: every folder in Data/Interface/AddOns whose .toc has `## X-ClassicPlus`
     (except `## X-Unlisted` ones, e.g. the GM console: shipped with the suite, never listed).
  3. GitHub topic search (`wow-vanilla-addon`, `vanilla-wow-addon`, `turtle-wow`) through the REST
     API (GITHUB_TOKEN raises the rate limit). New repositories become `listed: false` entries for a
     person to review; they never show on the site until someone sets `listed: true`.
  4. CurseForge through its official API, only when CURSEFORGE_KEY is set. CurseForge files are
     never rehosted (their terms), so these entries are always link-outs.

Verification: the GitHub API first (`/repos/{o}/{r}` and `/license`). When the API is not
reachable, the indexer falls back to `git ls-remote` (does the repository exist, what is its
default branch and head commit) and the raw LICENSE/COPYING file on raw.githubusercontent.com,
classified by text. An entry whose repository could not be reached at all keeps `verified: false`.

`rehost: true` only for the licences in workshop_lib.ALLOWED_LICENSES; everything else (no licence
file, "all rights reserved", CC-NC, AGPL, CurseForge) is a link to the author's page.

Hand edits survive: the indexer only (re)writes the fields it owns (source_url, verified, license
when it was detected, rehost, upstream.*), and creates missing entries. description, screenshots,
compat, tags and so on are left as a person wrote them.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import workshop_lib as W  # noqa: E402

TOPICS = ("wow-vanilla-addon", "vanilla-wow-addon", "turtle-wow")
UA = "OpenVanilla-Workshop-Indexer/1.0 (+https://openvanilla.app/workshop.html)"

# (id, name, author, category, [repo candidates, first that exists wins], summary, tags)
SEED = [
    ("pfui", "pfUI", "Shagu", "interface", ["shagu/pfUI"],
     "A complete replacement of the vanilla interface: unit frames, action bars, bags, chat, nameplates and more, all configurable in one window.", ["ui-suite", "unitframes", "actionbars"]),
    ("pfquest", "pfQuest", "Shagu", "quests", ["shagu/pfQuest"],
     "Quest helper and database browser: shows quest givers, objectives and turn-ins on the map and minimap.", ["questing", "database", "map"]),
    ("pfquest-turtle", "pfQuest (Turtle data)", "Shagu", "quests", ["shagu/pfQuest-turtle"],
     "Extra pfQuest database for the Turtle WoW content additions.", ["questing", "turtle-wow"]),
    ("pfquest-icons", "pfQuest Icons", "Shagu", "quests", ["shagu/pfQuest-icons"],
     "Icon pack add-on for pfQuest's map markers.", ["questing", "icons"]),
    ("shagutweaks", "ShaguTweaks", "Shagu", "interface", ["shagu/ShaguTweaks"],
     "A set of small, optional improvements to the stock interface, each one a switch.", ["tweaks", "quality-of-life"]),
    ("shaguplates", "ShaguPlates", "Shagu", "combat", ["shagu/ShaguPlates"],
     "pfUI's nameplates as a standalone addon: cast bars, debuffs and class colours on plates.", ["nameplates"]),
    ("shagudps", "ShaguDPS", "Shagu", "combat", ["shagu/ShaguDPS"],
     "A small damage and healing meter with a low memory footprint.", ["meter", "dps"]),
    ("shaguscore", "ShaguScore", "Shagu", "tooltips", ["shagu/ShaguScore"],
     "Adds an item score to item tooltips.", ["items", "tooltip"]),
    ("shaguinventory", "ShaguInventory", "Shagu", "bags", ["shagu/ShaguInventory"],
     "Tracks the items on your characters and shows the counts in tooltips.", ["inventory", "alts"]),
    ("shaguchat", "ShaguChat", "Shagu", "social", ["shagu/ShaguChat"],
     "Chat improvements in the pfUI style, as a standalone addon.", ["chat"]),
    ("shaguvalue", "ShaguValue", "Shagu", "tooltips", ["shagu/ShaguValue"],
     "Shows vendor sell prices in item tooltips.", ["vendor", "tooltip", "gold"]),
    ("shaguquest", "ShaguQuest", "Shagu", "quests", ["shagu/ShaguQuest"],
     "Quest log and quest tracker improvements.", ["questing"]),
    ("shagubop", "ShaguBoP", "Shagu", "utility", ["shagu/ShaguBoP"],
     "A small helper for bind-on-pickup loot prompts.", ["loot"]),
    ("shagucontroller", "ShaguController", "Shagu", "interface", ["shagu/ShaguController"],
     "Gamepad-friendly interface layout for playing vanilla with a controller.", ["gamepad", "controller"]),
    ("shagumount", "ShaguMount", "Shagu", "utility", ["shagu/ShaguMount"],
     "Mount helper.", ["mounts"]),
    ("pfui-eliteoverlay", "pfUI Elite Overlay", "Shagu", "unitframes", ["shagu/pfUI-eliteoverlay"],
     "Adds the elite and rare dragon to pfUI's target frame.", ["pfui-plugin"]),
    ("clique", "Clique", "Shagu (vanilla port)", "unitframes", ["shagu/Clique"],
     "Click-casting on unit frames: bind spells to mouse clicks with modifiers.", ["click-casting", "healing"]),
    ("antispam", "antispam", "Shagu", "social", ["shagu/antispam"],
     "Filters gold-seller and repeated spam out of chat.", ["chat", "spam"]),
    ("dpsmate", "DPSMate", "Geigerkind", "combat", ["Geigerkind/DPSMate"],
     "A full combat analysis meter: damage, healing, threat, deaths and more, with detailed breakdowns.", ["meter", "dps", "healing"]),
    ("modui", "modui", "obble", "interface", ["obble/modui"],
     "An interface overhaul that keeps the look of the stock UI while modernising it.", ["ui-suite"]),
    ("bigwigs", "BigWigs", "BigWigs authors (vanilla port by CosminPOP)", "raid", ["CosminPOP/BigWigs", "pepopo978/BigWigs", "laytya/BigWigs"],
     "Boss mod: timers, warnings and sounds for raid encounters.", ["boss-mod", "raiding"]),
    ("bigwigs-turtle", "BigWigs (Turtle WoW)", "pepopo978 and contributors", "raid", ["pepopo978/BigWigs"],
     "The BigWigs fork maintained for Turtle WoW's raids.", ["boss-mod", "raiding", "turtle-wow"]),
    ("ktm", "KLH Threat Meter", "Kenco (vanilla repack by laytya)", "combat", ["laytya/KLHThreatMeter"],
     "The classic raid threat meter, shared between raid members over addon messages.", ["threat", "raiding"]),
    ("twthreat", "TWThreat", "CosminPOP", "combat", ["CosminPOP/TWThreat"],
     "Threat meter built on Turtle WoW's server-side threat data.", ["threat", "turtle-wow"]),
    ("twlc2", "TWLC2", "CosminPOP", "raid", ["CosminPOP/TWLC2"],
     "Loot council for raid officers: votes, rolls and history.", ["loot", "guild"]),
    ("gatherer", "Gatherer", "Gatherer team (vanilla repack by laytya)", "professions", ["laytya/Gatherer"],
     "Remembers where you found herbs, ore and treasure and shows them on the map and minimap.", ["herbalism", "mining", "map"]),
    ("atlas", "Atlas", "Atlas team (vanilla repack)", "maps", ["laytya/Atlas", "Otari98/Atlas"],
     "Dungeon and raid maps with boss locations, in a window you can open anywhere.", ["dungeons", "maps"]),
    ("atlasloot", "AtlasLoot", "AtlasLoot team (Turtle WoW edition)", "raid", ["Otari98/AtlasLoot", "Haaxor1689/AtlasLoot"],
     "Browse the loot tables of dungeons, raids, crafting and sets.", ["loot", "database"]),
    ("onebag", "OneBag", "OneBag authors (vanilla repack by laytya)", "bags", ["laytya/OneBag"],
     "All your bags in one frame.", ["inventory"]),
    ("auctioneer", "Auctioneer", "Auctioneer team (vanilla repack by laytya)", "economy", ["laytya/Auctioneer"],
     "Scans the auction house and tracks prices; shows market values in tooltips.", ["auction", "gold"]),
    ("missingcrafts", "MissingCrafts", "refaim", "professions", ["refaim/MissingCrafts"],
     "Lists the recipes your profession is still missing and where to get them.", ["recipes"]),
    ("omnicc", "OmniCC", "Tuller (vanilla port by Otari98)", "interface", ["Otari98/OmniCC"],
     "Cooldown numbers on every action button and item.", ["cooldowns", "actionbars"]),
    ("supermacro", "SuperMacro", "Aldark (vanilla, maintained by Monteo)", "macros", ["Monteo/SuperMacro"],
     "Longer macros, extended Lua macros and a better macro editor.", ["macros"]),
    ("questie-vanilla", "Questie (1.12)", "Aero and the Questie team", "quests", ["AeroScripts/QuestieDev"],
     "The vanilla 1.12 Questie: quest givers and objectives on the map and minimap.", ["questing", "map"]),
    ("aux-addon", "aux", "shirsig", "economy", ["shirsig/aux-addon"],
     "A fast auction house replacement: search, post and track prices.", ["auction", "gold"]),
    ("wim", "WIM", "Pazza (vanilla, maintained by shirsig)", "social", ["shirsig/WIM", "EinBaum/WIM"],
     "WoW Instant Messenger: whispers in their own instant-messenger style windows.", ["whispers", "chat"]),
    ("cooldowns-shirsig", "Cooldowns", "shirsig", "combat", ["shirsig/Cooldowns"],
     "A compact bar of your spell and item cooldowns.", ["cooldowns"]),
    ("notoggle", "notoggle", "shirsig", "utility", ["shirsig/notoggle"],
     "Stops abilities from toggling off when pressed twice.", ["tweaks"]),
    ("unitframesimproved", "UnitFramesImproved", "Ko0z", "unitframes", ["Ko0z/UnitFramesImproved_Vanilla"],
     "Bigger, clearer stock unit frames with class colours and health numbers.", ["unitframes"]),
    ("supercleveroidmacros", "SuperCleveRoidMacros", "jrc13245 (after CleveRoid)", "macros", ["jrc13245/SuperCleveRoidMacros"],
     "Conditional macro syntax ([mod], [target=], [harm] ...) for 1.12; uses the SuperWoW client mod.", ["macros", "requires-superwow"]),
    ("ringmenu", "RingMenu", "jsb", "macros", ["jsb/RingMenu"],
     "A ring of action buttons that pops up around the cursor on a key press.", ["actionbars"]),
    ("decursive", "Decursive", "Archarodim (vanilla, maintained by Otari98)", "raid", ["Otari98/Decursive"],
     "One-click curing of curses, poisons, diseases and magic in groups and raids.", ["dispel", "healing"]),
    ("trinketmenu", "TrinketMenu", "Gello (vanilla, maintained by pepopo978)", "combat", ["pepopo978/TrinketMenu"],
     "Swap and use trinkets from a small menu; auto-queue trinkets on cooldown.", ["trinkets", "gear"]),
    ("turtletweaks", "TurtleTweaks", "mitjafelicijan", "interface", ["mitjafelicijan/TurtleTweaks"],
     "Tweaks and enhancements for the 1.12 client interface.", ["tweaks"]),
    ("itemtooltipicons", "ItemTooltipIcons", "refaim", "tooltips", ["refaim/ItemTooltipIcons"],
     "Profession icons in the tooltips of crafting ingredients.", ["professions", "tooltip"]),
    ("mastertradeskills", "MasterTradeSkills", "refaim", "professions", ["refaim/MasterTradeSkills"],
     "Adds trade skill information to the tooltips of ingredients.", ["recipes", "tooltip"]),
    ("soloraidtargeticons", "SoloRaidTargetIcons", "refaim", "utility", ["refaim/SoloRaidTargetIcons"],
     "Lets you put raid target icons on mobs while playing solo.", ["targeting"]),
    ("vanilla-iconic", "Iconic", "alchem1ster", "macros", ["alchem1ster/Vanilla-Iconic"],
     "Adds a search bar to the macro icon picker.", ["macros", "icons"]),
    ("vanilla-newlevelframe", "NewLevelFrame", "alchem1ster", "interface", ["alchem1ster/Vanilla-NewLevelFrame"],
     "A simple level-up frame that shows what you gained.", ["leveling"]),
    ("necrosis-twow", "Necrosis", "Necrosis authors (Turtle WoW fork by BlackHobbiT)", "combat", ["BlackHobbiT/necrosis-twow"],
     "The warlock companion: soul shard counter, summons, stones and timers.", ["warlock", "class"]),
    ("shadowtrancealert", "ShadowTranceAlert", "wsmaxcy", "combat", ["wsmaxcy/ShadowTranceAlert"],
     "Shows an alert when a Shadow Trance proc happens.", ["warlock", "class"]),
    ("timeofdayindicator", "TimeOfDayIndicator", "vicitafirea", "interface", ["vicitafirea/TimeOfDayIndicator-AddOn"],
     "A replacement for the stock day/night indicator.", ["minimap"]),
    ("warcraftui-upperbar", "WarcraftUI UpperBar", "vicitafirea", "interface", ["vicitafirea/WarcraftUI-UpperBar-AddOn"],
     "A bar along the top of the screen with information at a glance.", ["infobar"]),
    ("interfacecolors", "InterfaceColors", "vicitafirea", "interface", ["vicitafirea/InterfaceColors-Addon"],
     "Replaces the stock interface colours, for example for reputation levels.", ["colors"]),
    ("turtlechatcolors", "TurtleChatColors", "DaMaGepyHUN", "social", ["DaMaGepyHUN/TurtleChatColors"],
     "Chat colour adjustments for Turtle WoW's channels.", ["chat", "turtle-wow"]),
    ("vendorlist", "VendorList", "MarcelineVQ", "economy", ["MarcelineVQ/VendorList"],
     "A list of what vendors sell.", ["vendor"]),
    ("minimapbuttonbag", "MinimapButtonBag", "McPewPew", "interface", ["McPewPew/MinimapButtonBag", "doorknob6/MinimapButtonBag"],
     "Collects the minimap buttons of other addons into one bag.", ["minimap"]),
    ("bagshui", "Bagshui", "veechs", "bags", ["veechs/Bagshui", "NiclasEriksen/Bagshui"],
     "All-in-one auto-categorising and sorting inventory with a customisable layout.", ["inventory", "sorting"]),
    ("healersmate", "HealersMate", "OldManAlpha", "raid", ["OldManAlpha/HealersMate"],
     "Healing frames for parties and raids with click-casting.", ["healing", "unitframes"]),
    ("rinse", "Rinse", "Otari98", "raid", ["Otari98/Rinse"],
     "A small decursive: shows who needs a dispel and cleanses with a click.", ["dispel", "healing"]),
    ("levelrange-turtle", "LevelRange (Turtle)", "Spartelfant", "maps", ["Spartelfant/LevelRange-Turtle"],
     "Shows each zone's level range on the world map, with Turtle WoW's zones.", ["map", "leveling"]),
    ("msbt-vanilla", "MikScrollingBattleText", "Mik (vanilla port by jrc13245)", "combat", ["jrc13245/Vanilla_MikScrollingBattleText"],
     "Scrolling combat text you can shape: damage, heals, procs and notifications in separate areas.", ["combat-text"]),
    ("magnify", "Magnify", "luskanek", "maps", ["luskanek/Magnify"],
     "Zoom and pan the world map.", ["map"]),
    ("bettercharacterstats", "BetterCharacterStats", "pepopo978", "tooltips", ["pepopo978/BetterCharacterStats"],
     "More stats on the character sheet: hit, crit, spell power and more.", ["character", "stats"]),
    ("unitscan-turtle-hc", "unitscan (Turtle HC)", "RetroCro", "utility", ["RetroCro/unitscan-turtle-hc"],
     "Warns you when a dangerous or rare unit is nearby.", ["hardcore", "rares"]),
    ("hardcorechattamer", "TurtleHardcoreChatTamer", "refaim", "social", ["refaim/TurtleHardcoreChatTamer"],
     "Tames the Turtle WoW hardcore chat announcements.", ["chat", "hardcore"]),
    ("tabib", "Tabib", "mistweaverco", "raid", ["mistweaverco/twow-addon-tabib"],
     "Simple healing frames with automatic down-ranking.", ["healing"]),
    ("herbalists-handbook", "Herbalist's Handbook", "Byzzon", "professions", ["Byzzon/herbalists-handbook"],
     "An overview of every herb and where to gather it.", ["herbalism"]),
    ("autodecline", "AutoDecline", "mrrosh", "utility", ["mrrosh/AutoDecline"],
     "Declines duel, guild and party invitations automatically, with exceptions.", ["tweaks"]),
    ("gryllsexpbar", "GryllsExpBar", "Grylls", "interface", ["GryllsAddons/GryllsExpBar"],
     "An experience bar with rested and quest experience.", ["leveling"]),
    ("hcwarn", "HCWarn", "Grylls", "utility", ["GryllsAddons/HCWarn"],
     "Hardcore warnings for dangerous situations.", ["hardcore"]),
    ("notanewcomer", "NotANewcomer", "JoLiKMC", "utility", ["JoLiKMC/NotANewcomer"],
     "Leaves the Newcomers guild automatically on login.", ["guild", "turtle-wow"]),
    ("pfui-addonskinner", "pfUI AddonSkinner", "mrrosh", "interface", ["mrrosh/pfUI-addonskinner"],
     "Skins other addons' windows in pfUI's style.", ["pfui-plugin", "skins"]),
    # Well-known addons whose maintained 1.12 repository we have not pinned down yet: listed as
    # link-outs (no repository, verified: false) until someone fills in source_url.
    ("bagnon", "Bagnon", "Tuller", "bags", [], "All your bags in one window, and your bank in another.", ["inventory"]),
    ("cartographer", "Cartographer", "ckknight", "maps", [], "A modular world map: notes, fog clearing, instance maps and more.", ["map"]),
    ("mobinfo2", "MobInfo2", "Dizzarian and contributors", "tooltips", [], "Adds mob health, mana, loot and kill statistics to tooltips.", ["tooltip", "mobs"]),
    ("postal", "Postal", "Postal authors", "social", [], "Mailbox improvements: open all, bulk send, quick reply.", ["mail"]),
    ("sw-stats", "SW_Stats", "Shadowwind", "combat", [], "A detailed damage and healing meter of the vanilla era.", ["meter", "dps"]),
    ("titan-panel", "Titan Panel", "Titan Panel team", "interface", [], "Information bars along the screen edge with plug-ins for gold, bags, location and more.", ["infobar"]),
    ("eqcompare", "EQCompare", "Legorol", "tooltips", [], "Compares an item with what you have equipped, side by side in the tooltip.", ["gear", "tooltip"]),
    ("enginventory", "EngInventory", "Engineer", "bags", [], "One sorted bag window that groups items by type.", ["inventory", "sorting"]),
]


# ------------------------------------------------------------------------------------- fetching

class Net:
    """Network access, swappable in tests. Every method returns (ok, value_or_reason)."""

    def __init__(self, token=None, timeout=20):
        self.token = token
        self.timeout = timeout
        self.api_blocked = None   # set to a reason after the first refused API call

    def http(self, url, headers=None):
        req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return True, r.read()
        except urllib.error.HTTPError as e:
            return False, f"HTTP {e.code}"
        except (urllib.error.URLError, OSError) as e:
            return False, str(getattr(e, "reason", e))

    def github_api(self, path):
        if self.api_blocked:
            return False, self.api_blocked
        h = {"Accept": "application/vnd.github+json"}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        ok, v = self.http("https://api.github.com" + path, h)
        if not ok and v in ("HTTP 403", "HTTP 401", "HTTP 407") or (not ok and "403" in str(v)):
            self.api_blocked = f"GitHub API refused ({v})"
        if ok:
            try:
                return True, json.loads(v)
            except ValueError:
                return False, "bad JSON from the GitHub API"
        return False, v

    def ls_remote(self, repo):
        try:
            p = subprocess.run(["git", "ls-remote", "--symref", f"https://github.com/{repo}", "HEAD"],
                               capture_output=True, text=True, timeout=60,
                               env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
        except (OSError, subprocess.TimeoutExpired) as e:
            return False, str(e)
        if p.returncode != 0 or not p.stdout.strip():
            return False, (p.stderr.strip().splitlines() or ["no answer"])[-1]
        return True, p.stdout

    def raw(self, repo, branch, path):
        ok, v = self.http(f"https://raw.githubusercontent.com/{repo}/{branch}/{path}")
        return ok, (v.decode("utf-8", "replace") if ok else v)


def parse_ls_remote(text):
    """`git ls-remote --symref URL HEAD` -> (default_branch, head_sha) or (None, None)."""
    branch = sha = None
    for line in (text or "").splitlines():
        m = re.match(r"^ref:\s+refs/heads/(\S+)\s+HEAD$", line)
        if m:
            branch = m.group(1)
            continue
        m = re.match(r"^([0-9a-f]{40})\s+HEAD$", line)
        if m:
            sha = m.group(1)
    return branch, sha


def parse_repo_json(data):
    """GitHub /repos/{o}/{r} -> the fields we keep."""
    lic = (data.get("license") or {}).get("spdx_id")
    return {
        "full_name": data.get("full_name"),
        "default_branch": data.get("default_branch"),
        "description": data.get("description") or "",
        "homepage": data.get("homepage") or "",
        "stars": data.get("stargazers_count", 0),
        "archived": bool(data.get("archived")),
        "pushed_at": data.get("pushed_at"),
        "license": W.norm_license(lic if lic and lic != "NOASSERTION" else None),
        "owner": (data.get("owner") or {}).get("login"),
        "topics": data.get("topics") or [],
    }


def parse_topic_search(data):
    """GitHub /search/repositories -> [repo dict] (skips forks)."""
    return [parse_repo_json(it) for it in (data or {}).get("items", []) if not it.get("fork")]


def parse_curseforge(data):
    """CurseForge /v1/mods/search -> [{id, name, author, summary, homepage, downloads}]."""
    out = []
    for m in (data or {}).get("data", []):
        authors = ", ".join(a.get("name", "") for a in m.get("authors", []) if a.get("name"))
        out.append({
            "cf_id": m.get("id"),
            "name": m.get("name", ""),
            "author": authors or "unknown",
            "summary": m.get("summary", ""),
            "homepage": (m.get("links") or {}).get("websiteUrl") or "",
            "downloads": int(m.get("downloadCount") or 0),
        })
    return out


LICENSE_FILES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "COPYING", "COPYING.txt", "license.txt", "License.txt")


def check_repo(net, repo):
    """Everything we can learn about one GitHub repository. Always returns a dict with `exists`
    (True / False / None = could not tell) and `how` (which path answered)."""
    ok, data = net.github_api(f"/repos/{repo}")
    if ok:
        info = parse_repo_json(data)
        info.update(exists=True, how="api")
        ok2, sha = net.github_api(f"/repos/{repo}/commits/{info['default_branch']}")
        if ok2 and isinstance(sha, dict):
            info["commit"] = sha.get("sha")
        return info
    if data == "HTTP 404" and not net.api_blocked:
        return {"exists": False, "how": "api", "reason": "not found"}
    ok, out = net.ls_remote(repo)
    if not ok:
        return {"exists": None, "how": "git", "reason": out}
    branch, sha = parse_ls_remote(out)
    info = {"exists": True, "how": "git", "full_name": repo, "default_branch": branch or "master", "commit": sha,
            "license": "NOASSERTION"}
    for name in LICENSE_FILES:
        ok, text = net.raw(repo, info["default_branch"], name)
        if ok:
            info["license"] = W.classify_license_text(text)
            info["license_file"] = name
            break
    return info


# ------------------------------------------------------------------------------------ catalogue

def today():
    return dt.date.today().isoformat()


def seed_entry(row):
    sid, name, author, cat, repos, summary, tags = row
    return {
        "id": sid, "name": name, "author": author, "summary": summary, "description": summary,
        "category": cat, "license": "NOASSERTION", "rehost": False,
        "source_url": f"https://github.com/{repos[0]}" if repos else None,
        "homepage": f"https://github.com/{repos[0]}" if repos else None,
        "version": None, "added": today(), "screenshots": [], "tags": list(tags), "compat": "unknown",
        "ours": False, "verified": False, "upstream": {"repos": list(repos)},
    }


def apply_check(entry, info, repo):
    """Fold a check_repo() answer into an entry (only the fields the indexer owns)."""
    up = entry.setdefault("upstream", {})
    up["checked"] = today()
    up["how"] = info.get("how")
    if info.get("exists") is True:
        entry["source_url"] = f"https://github.com/{info.get('full_name') or repo}"
        if not entry.get("homepage") or "github.com/" in str(entry.get("homepage")):
            entry["homepage"] = info.get("homepage") or entry["source_url"]
        up["repo"] = info.get("full_name") or repo
        up["branch"] = info.get("default_branch")
        if info.get("commit"):
            up["commit"] = info["commit"]
            entry["version"] = entry.get("version") or ("git-" + info["commit"][:7])
        if info.get("license_file"):
            up["license_file"] = info["license_file"]
        if not entry.get("license_locked"):
            entry["license"] = info.get("license") or "NOASSERTION"
        entry["verified"] = True
        up.pop("reason", None)
    else:
        entry["verified"] = False
        up["reason"] = info.get("reason") or "not reachable"
    entry["rehost"] = W.may_rehost(entry.get("license")) and not entry.get("no_rehost", False)
    return entry


def ours_entries(addons_dir=W.ADDONS_DIR):
    """One entry per Classic+ addon folder (## X-ClassicPlus in its .toc)."""
    out = []
    if not os.path.isdir(addons_dir):
        return out
    for folder in sorted(os.listdir(addons_dir), key=str.lower):
        toc = W.read_toc(os.path.join(addons_dir, folder, folder + ".toc"))
        if not toc or "X-ClassicPlus" not in toc["meta"]:
            continue
        if toc["meta"].get("X-Unlisted"):
            continue   # ships with the suite but stays out of every list players see (the GM console)
        m = toc["meta"]
        notes = W.strip_codes(m.get("Notes", ""))
        shot = "assets/addons/%s.webp" % str(m.get("X-ClassicPlus", "")).strip().lower()
        shots = [shot] if os.path.isfile(os.path.join(W.ROOT, "www", shot)) else []
        out.append({
            "id": "cp-" + W.slug(folder), "name": W.strip_codes(m.get("Title", folder)), "author": m.get("Author", "Open Vanilla"),
            "summary": notes.split(". ")[0].rstrip(".") + "." if notes else f"{folder}, part of the Open Vanilla Classic+ suite.",
            "description": notes or f"{folder}, part of the Open Vanilla Classic+ suite.",
            "category": "classicplus", "license": W.norm_license(m.get("X-License")) if m.get("X-License") else "Open Vanilla", "rehost": True,
            "source_url": "https://github.com/orionopenwow/OpenVanilla/tree/main/Data/Interface/AddOns/" + folder,
            "homepage": "https://openvanilla.app/", "version": m.get("Version") or None, "added": today(),
            "screenshots": shots, "tags": ["classic-plus"], "compat": "works", "ours": True, "folders": [folder],
            "verified": True, "upstream": {"classicplus": m.get("X-ClassicPlus"), "deps": m.get("Dependencies", "")},
        })
    return out


def merge(existing, fresh, owned=("upstream",)):
    """Keep a person's edits: start from the fresh entry, overlay every existing field except the
    ones the indexer owns."""
    out = dict(fresh)
    for k, v in (existing or {}).items():
        if k in owned or (v in (None, "", [], {}) and out.get(k) not in (None, "", [], {})):
            continue   # the indexer's field, or an empty value that was never a person's edit
        out[k] = v
    return out


def run(args, net=None, log=print):
    net = net or Net(token=os.environ.get("GITHUB_TOKEN"))
    have = {e["id"]: e for e in W.load_catalog(args.catalog)}
    only = set(filter(None, (args.only or "").split(",")))
    written, notes = [], []

    for row in SEED:
        if only and row[0] not in only:
            continue
        entry = merge(have.get(row[0]), seed_entry(row))
        if not args.offline and row[4]:
            info = {"exists": None, "reason": "no candidate answered"}
            for repo in (entry.get("upstream", {}).get("repos") or row[4]):
                info = check_repo(net, repo)
                if info.get("exists"):
                    apply_check(entry, info, repo)
                    break
            else:
                apply_check(entry, info, row[4][0])
        elif have.get(row[0], {}).get("upstream"):
            entry["upstream"] = have[row[0]]["upstream"]
        entry["rehost"] = W.may_rehost(entry.get("license")) and not entry.get("no_rehost", False)
        written.append(W.write_entry(entry, args.catalog))

    for e in ours_entries(args.addons):
        if only and e["id"] not in only:
            continue
        old = have.get(e["id"])
        written.append(W.write_entry(merge(old, e, owned=("upstream", "version", "description", "summary", "folders"))
                                     if old else e, args.catalog))

    if not args.offline and not only:
        for topic in TOPICS:
            ok, data = net.github_api(f"/search/repositories?q=topic:{topic}&per_page=100")
            if not ok:
                notes.append(f"topic {topic}: {data}")
                continue
            for repo in parse_topic_search(data):
                rid = W.slug(repo["full_name"].split("/")[1])
                if rid in have or any(os.path.basename(p) == rid + ".yml" for p in written):
                    continue
                e = {"id": rid, "name": repo["full_name"].split("/")[1], "author": repo.get("owner") or "",
                     "summary": repo["description"][:200], "description": repo["description"], "category": "utility",
                     "license": repo["license"], "rehost": W.may_rehost(repo["license"]),
                     "source_url": "https://github.com/" + repo["full_name"], "homepage": repo["homepage"] or
                     "https://github.com/" + repo["full_name"], "version": None, "added": today(), "screenshots": [],
                     "tags": [topic], "compat": "unknown", "ours": False, "verified": True, "listed": False,
                     "upstream": {"repo": repo["full_name"], "branch": repo["default_branch"], "how": "api-topic"}}
                written.append(W.write_entry(e, args.catalog))

        key = os.environ.get("CURSEFORGE_KEY")
        if key:
            ok, raw = net.http("https://api.curseforge.com/v1/mods/search?gameId=1&gameVersion=1.12.1&pageSize=50",
                               {"x-api-key": key, "Accept": "application/json"})
            if ok:
                for m in parse_curseforge(json.loads(raw)):
                    rid = W.slug(m["name"])
                    if rid in have:
                        continue
                    written.append(W.write_entry({
                        "id": rid, "name": m["name"], "author": m["author"], "summary": m["summary"],
                        "description": m["summary"], "category": "utility", "license": "Proprietary", "rehost": False,
                        "source_url": None, "homepage": m["homepage"], "version": None, "added": today(),
                        "screenshots": [], "tags": ["curseforge"], "compat": "unknown", "ours": False, "verified": True,
                        "listed": False, "no_rehost": True, "upstream": {"curseforge": m["cf_id"]}}, args.catalog))
            else:
                notes.append(f"curseforge: {raw}")
        else:
            notes.append("curseforge: skipped (CURSEFORGE_KEY not set)")

    if net.api_blocked:
        notes.append(net.api_blocked + "; verified through git ls-remote + raw LICENSE files instead")
    for n in notes:
        log("note: " + n)
    log(f"wrote {len(written)} catalogue entries to {args.catalog}")
    return written, notes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--catalog", default=W.CATALOG_DIR)
    ap.add_argument("--addons", default=W.ADDONS_DIR)
    ap.add_argument("--offline", action="store_true", help="no network; entries keep their verified flag")
    ap.add_argument("--only", help="comma-separated ids")
    args = ap.parse_args(argv)
    run(args)


if __name__ == "__main__":
    main()
