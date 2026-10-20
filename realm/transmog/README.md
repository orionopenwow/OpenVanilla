# Transmog — retail's appearance system on 1.12.1

Retail World of Warcraft's transmogrification as it works since Midnight (12.x), built for the
Open Vanilla world server and the stock 1.12.1 client (and wenilla). Off unless a realm turns it
on with `OpenVanilla.Transmog = 1`.

## How it plays (retail's rules)

- **Collecting.** An item's appearance is learned account-wide when the item binds to you:
  bind-on-pickup items when looted, bind-on-equip items when equipped. Every choice in a quest's
  reward list is learned too, not only the one you take. Any quality counts, grey included. The
  first time a character loads, the realm learns everything it already wears or holds bound.
- **Outfits, not items.** Looks are saved to gear *slots* inside an outfit. New gear keeps the
  look. Switching between saved outfits is free and works anywhere: in the window, with
  `/outfit 2` or `/outfit <name>`, or from a macro on your action bar.
- **Changing an outfit** is done at a Transmogrifier and costs gold: half the look item's vendor
  price for each changed slot (at least 1 silver), 1 gold 50 silver for an illusion. Hiding a slot or
  going back to the item you wear is free. Each character's first saved outfit is free.
- **Outfit slots.** 2 are free; more are unlocked for the whole account at retail's price list
  (100, 200, 350, 500, 1,000 … 100,000 gold) times `OpenVanilla.Transmog.PriceScale`, 50 at most.
- **What fits.** A look must suit the slot (chest and robe share one), be the class's armor type
  (cloth, leather, mail or plate; cloaks, shirts and tabards any), and be usable by the class and
  race. Weapons follow retail's groups: bows, crossbows and guns · two-handed axes, maces, swords,
  staves and polearms · one-handed axes, maces, swords and fist weapons · daggers · a wand also
  takes a dagger, one-handed sword or one-handed mace look · shields · off-hand items. When the item
  you wear can't take the saved look (a dagger look while holding a staff), it shows itself.
- **Hidden appearances** for helm, shoulders, cloak, chest, shirt, tabard, belt, legs, wrists, hands
  and feet.
- **Illusions.** A weapon enchantment's glow, learned when such an enchantment is put on one of your
  weapons, shown on the main hand or off hand of an outfit.
- **Situations.** An outfit can put itself on when *all* of its chosen categories match: location
  (resting, world, dungeon, raid, battleground), movement (on foot, swimming, mounted), time of day,
  weather (clear, rain, snow, sandstorm) and specialization (with dual spec). When several match,
  the lowest-numbered one wins; when none does, the outfit you picked comes back.
- **Custom sets.** Free, unlimited (100 per account) collections of looks to keep or share in chat
  as a link anyone with the addon can preview.

## The window (`Data/Interface/AddOns/Transmog`)

Opens at a Transmogrifier (Lyriel Threadweave in Stormwind, Ironforge, Darnassus and Booty Bay;
Morga Silkhand in Orgrimmar, the Undercity, Thunder Bluff and Gadgetzan), with `/transmog`
(`/tmog`, `/appearances`) anywhere to browse and switch, or from the "Appearances" menu row.
It follows the Open Vanilla mockup:

- **Left, Outfits (n/50):** cards with the outfit's icon and name. The outfit you wear carries a
  green *Active* pill; one that puts itself on (situations) a gold shield. The cog and right-click
  hold rename, icon, situations and "wear no outfit". *+ New Outfit* unlocks the next slot.
- **Middle:** your character on a stone dais in your race's dressing room, the 14 slots around it.
  The chosen slot has a gold rim (a bracket points from the right-hand ones to the collection),
  a changed slot glows purple, a hidden one shows a red cross. Under it, the view toolbar (turn,
  reset, slow spin, zoom on the slot, compare with your gear) and Main Hand / Off-Hand / Ranged.
- **Right:** Items (search, *Filter*: usable only, Illusions for weapons, 3D previews; a 4 x 4 page
  of the looks collected for the slot, rimmed in their quality's colour, *Hidden* first), Sets,
  Custom Sets and Situations; then the cost, *Apply Transmog* and *Revert Changes*.
- **Tooltips** say "You haven't collected this appearance" or "You've collected this appearance,
  but not from this item", as retail does.

The art (frame, banner, cards, buttons, dais, toolbar, rims) is original, drawn by
`tools/transmog/make_art.py` into `Art/` as 1.12-ready TGAs; the dressing-room backdrops are the
game's own (`Interface\DressUpFrame`), read from the player's client.

**3D in the browser client.** wenilla drew a model pane only for the game's own named windows, so
an addon's `DressUpModel` showed nothing. Client patch `realm/patches/0019-openvanilla-dressing-room.patch`
gives the one dressing room to the named `DressUpModel` that acted last (here `TransmogModel`): it
draws there, turns with its `SetRotation` and empties when it's hidden; anonymous panes (the grid's
cells) can no longer undress it. The patch sets `OPENVANILLA_ONE_DRESSING_ROOM`, and the window
then shows icons in the grid. The stock 1.12 client draws every model itself and needs nothing.

The addon talks to the realm over the WNL channel (`.wnl tm …`, answers tagged `TM`). The whole
protocol is at the top of `src/game/OpenVanilla/Transmog.h` in patch 0011. It stays inert on realms
that don't answer.

## Files

| Part | Where |
|---|---|
| World server | `realm/mangos/0011-openvanilla-transmog.patch`: `src/game/OpenVanilla/Transmog*.{h,cpp}` plus small hooks in `Player.cpp` (visible item, bind, equip, enchant, quest reward, character deletion), `WorldSession.cpp`, `Wnl.cpp` and `Weather.h`. Applies on 0001–0005 + 0010, and on 0001–0010. |
| Characters SQL | `transmog_characters.sql`: account collection, outfit slots, per-character outfits, custom sets |
| World SQL | `transmog_world.sql`: the two Transmogrifiers (entries 990300/990301) and 8 spawns beside the capital and goblin-town innkeepers (guids 9100301–9100308) |
| Addon | `Data/Interface/AddOns/Transmog` with its `Art/` (goes into patch-Z with the next rebuild) |
| Browser client | `realm/patches/0019-openvanilla-dressing-room.patch` (wenilla: the 3D model in addon windows) |
| Art source | `tools/transmog/make_art.py` |
| Tests | `tests/run_logic_tests.sh` (60 rule tests, no server), `devkit/sim/tests/transmog.lua` (13 window tests), `devkit/heraldlite/scenarios/transmog_*.txt` (4 in-game scenarios), `devkit/sim/render/transmog.lua` (pictures of the window) |

## mangosd.conf

| Key | Default | |
|---|---|---|
| `OpenVanilla.Transmog` | 0 | turn it on |
| `OpenVanilla.Transmog.PriceScale` | 0.01 | retail's gold prices × this (vanilla gold is worth ~100× retail's) |
| `OpenVanilla.Transmog.MaxOutfits` | 50 | outfit slots per account at most |
| `OpenVanilla.Transmog.RequireNpc` | 1 | 0 lets changes be saved anywhere |

`hetzner/warfront_up.sh` sets `OpenVanilla.Transmog=1` and applies both SQL files for Warfront. On
another realm: apply the two files, add the key, restart the world server.

## Tested

| What | How | Result |
|---|---|---|
| Rules (groups, prices, parsing, situations) | `tests/run_logic_tests.sh` | 60/60 |
| The window's behaviour | `lua5.1 devkit/sim/run_tests.lua . transmog` | 13/13 (whole suite 464/464) |
| The window's look | `devkit/sim/render` (below): every tab and state drawn with the game's own UI textures, compared with the mockup side by side | matches the mockup's layout and finish |
| In game, `transmog_smoke.txt` | collection from worn gear, learning on bind, cloth refused for a Hunter, the Transmogrifier rule, the free first save, the look on the visible slot, a hidden helm, free switching away from the NPC, the outfit kept across a relog, situations switching on and back, unlocking a slot | 70/70 |
| In game, `transmog_weapons.txt` | weapon groups, weapons can't be hidden, the exact gold charged (1,650 and 1,005 copper, checked in the database), names, icons, custom sets | 52/52 |
| In game, `transmog_learning.txt` | an enchantment's glow learned as an illusion, saved over the real enchantment and switched with the outfit, refused on a ranged weapon; every reward choice of a quest learned, the cloth left behind included | 54/54 |
| Under load, `run_transmog_stress.sh 12 300 2` | 12 bots at once, 300 random commands each (valid, refused, malformed, oversized, relogs, NPC hops, unlocks, custom sets) plus the smoke scenario as a real player; then the server log and 8 table invariants | all pass, server up, tick steady at 50 ms (max 54), invariants 0 |
| In game, `transmog_spawns.txt` | all 8 Transmogrifiers in view where the SQL puts them, each within half a yard of the floor under it | 43/43 |
| Character deletion | `.character erase` on a character with outfits: its outfit rows go, the account's collection stays | checked in the database |

The in-game scenarios run with Herald Lite against a test realm with `OpenVanilla.Transmog = 1`; two
level 60 GM characters (`HL_USER` a Warfront Hunter in gear, `HL_USER2`). Learning is announced
once per account, so before running `transmog_learning.txt` again on the same realm clear what it
teaches:
```
DELETE i FROM transmog_illusion i JOIN characters c ON c.account = i.account WHERE c.name = '<HL_CHAR>';
DELETE s FROM transmog_source s JOIN characters c ON c.account = s.account WHERE c.name = '<HL_CHAR2>' AND s.item IN (9623, 9624, 9625);
```

### Pictures of the window

```
lua5.1 devkit/sim/render/shoot.lua . devkit/sim/render/transmog.lua _local/shots
python3 devkit/sim/render/render.py . _local/shots          # _local/shots/transmog_*.png
```
Needs the game's UI textures extracted under `Data/Interface` (as for local testing; they are
git-ignored and never shipped). The 3D model can't be drawn there: it shows the items it wears.

## Known limits

- **Inspect** shows the look, not the real item: the 1.12 client reads inspected gear from the same
  visible fields. Retail does the same for the model, but there the tooltip shows the real item.
- **No separate shoulders, no weapon sheath options**: the 1.12 client can't draw them.
- **Situations by weather** follow the zone's server weather; Tanaris and Silithus count their
  "rain" as sandstorm.
- **Not yet seen in a real client**: the camera framing of the 3D model cells in the Items grid
  (`SLOT_VIEW` in `Window.lua`); the pictures above show everything else.

## Art wanted

The window works today with stock 1.12 icons. These would give it its own look. As with
Warfront, it must all be **original art**, never images taken from the game files.

| # | Piece | Size | Where |
|---|---|---|---|
| 1 | Appearances crest (a mirror or a dress form with a soft glow) | 256×256, transparent | window title icon, menu row, Transmogrifier gossip icon |
| 2 | Pending-change glow (soft violet ring) | 64×64, transparent | the slot buttons around the model |
| 3 | Hidden-slot mark (a crossed-out eye) | 64×64, transparent | hidden slots and the Hidden cell |
| 4 | Situation icons: location, movement, time of day, weather, specialization | 64×64 each, transparent | Situations tab, the Auto badge |
| 5 | Model backdrop (a dim dressing room, vignette) | 512×512, opaque | behind the character model |
| 6 | Collection cell frame (thin gold edge, darker for not usable) | 128×128, transparent | the Items grid |

Highest value first: 1, 2, 5.
