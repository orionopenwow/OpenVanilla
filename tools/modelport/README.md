# Open Vanilla Model Porter

Turns a rigged, animated **.glb / .gltf**, or a **modern-format model** (.m2 with its .skin,
.skel, .anim and .blp files), into a Vanilla model (M2 + BLP textures) and adds it
to Open Vanilla as a creature or a rideable mount.

**Start it:** double-click `Model_Porter.bat` (or drop .glb files onto it). The app opens in your
browser at http://127.0.0.1:8765. Drop a model, check the preview, press **Add to Open Vanilla**, then run
`Ship.bat` and `Release.bat` as usual.

## What carries over

| From the glTF | In the game |
|---|---|
| Skinned meshes, up to 4 weights per vertex | M2 vertices; parts with more than 64 bones are split automatically |
| The skeleton (up to 254 bones) | M2 bones: pivots at the joints, keys sampled at 30 fps plus every source key, then thinned |
| Animation clips | Vanilla animations, matched by name (see below), each on the game's own timeline |
| Base colour texture and colour factor | BLP2 DXT1 (opaque) or DXT5 (alpha), full mip chain, 256–1024 px |
| Flat-colour materials (no texture) | Packed into one swatch texture: one draw call, not dozens |
| Double-sided, alpha mask/blend, unlit | M2 render flags and blend modes |
| A node named `Seat` (or `Saddle`) | The rider's attachment point on a mount |
| Nodes named `Attach_<n>` | Attachment point `n` (11 helm, 18 name plate, 19 base, 20 head, …) |
| Unskinned meshes under a node | Rigid parts that follow that node |

Dropped, with a note in the report: normal/roughness/metal maps, shape keys (morph targets), second
UV sets, texture transforms, cameras and lights. More than 21,845 triangles is decimated
automatically (the Vanilla format's 16-bit index ranges); decimating in Blender first looks better.

Every port is checked by reading it back the way the engine does; poses match the glTF within a
fraction of a percent of the model's size.

## Modern-format models (.m2 + .skin / .skel / .anim / .blp)

Models saved in the model format of Wrath and later (version 264–274: chunked MD21 or plain MD20)
convert too. Drop **all of a model's files together**: the `.m2`, its `Name00.skin`, the `.skel`
if it has one, every `.anim` (`Name0005-00.anim` …) and the `.blp` textures. What's read:

- the mesh from skin 0 (every part; optional geoset variants are all kept, with a note),
- the skeleton and attachments, from the `.skel` (SKB1/SKA1) when there is one,
- every animation with its id, length and speed, whether stored inline, in the `.skel`, or in
  `.anim` files; compressed rotations are expanded; ids newer than Vanilla show as `RetailNNN`
  and are skipped unless you pick a Vanilla animation for them,
- textures by file name, by TXID file id (`12345.blp`), or the `.blp` files beside the model,
  in any BLP2 form (palettized, DXT1/3/5, raw).

Not carried: particles, ribbons, lights, texture animations, extra texture layers (the first
layer is drawn), and a parent skeleton (`SKPD`) — export those models with their full skeleton.
The conversion goes through a `.glb` (kept as `source.glb` in content/models), so the preview,
checks and limits are the same as for glTF.

## Naming clips

Clips are matched by name, case and punctuation ignored: `Idle`, `Walk`, `Run`/`Gallop`,
`Sprint`, `WalkBackwards`, `JumpStart`, `Jump`, `JumpEnd`/`Land`, `Fall`, `Swim`, `SwimIdle`,
`Death`, `Attack`/`Bite`, `Roar`/`Neigh`, `Rear`, `Eat`/`Graze`, `Sit`, `Sleep`, and every name in
AnimationData.dbc (`EmoteDance`, `SpellCast`, …). `Walk_2` is a second variation of Walk; `[37]`
anywhere in a name forces animation id 37. Anything else can be picked in the app's table.

Missing clips fall back sensibly: no Walkbackwards → the walk played in reverse; no Run → the walk
(and the other way round); no idle → the rest pose.

**Speed:** for walk and run clips, the yards per second the clip is drawn at. The game plays the
clip faster or slower to match how fast the mount moves, so the feet don't slide. Clips with root
motion (the model walks off) are measured and kept in place; in-place clips use 2.5 (walk) and
11 (mount run) unless you set it. The preview's moving ground shows whether it's right.

## Exporting from Blender

- File → Export → glTF 2.0, format **glTF Binary (.glb)**. Include: selected objects or the whole
  scene; Transform +Y Up; Mesh: Apply Modifiers, UVs, Normals; Animation: Animations, Group by NLA
  Track or Actions, **Always Sample Animations**.
- Model in metres facing Blender's −Y (front view). The porter turns it to face the game's forward.
- For a mount, add an Empty named **Seat**, parented to the spine bone, where the rider's hips go.
- Keep it game-sized: 3,000–12,000 triangles and one 512 px texture is typical for a mount.

## IDs and files

The app keeps everything in the Open Vanilla folder:

- `content/models/registry.json`: every model and its IDs (model data from 3000, displays from
  20000, creatures from 991000, mount spells from 40000, items from 991500)
- `content/models/<Name>/`: the source file, the settings, and `game/` (the M2 and textures)
- `Data/ClassicPlusDBC/`: the Vanilla tables with the new rows (made from `Data/dbfilesclient`, not in
  git). The game files and these tables go into `realm/classicplus/patch-Z.MPQ`, rebuilt by the app
  or by `tools/sync_patchz.py`
- `realm/classicplus/classicplus_world_models.sql`: creatures, mount spells and reins items for
  the server; `classicplus_world_models.json` + `apply_models_dbc.py` give mangosd the same rows

**Testing in game (GM):** `.additem <item>` for the reins, `.npc add <creature>` to spawn it,
`.modify morph <display>` to wear it, `.demorph` to stop.

Command line: `python tools/modelport model.glb --name X --kind mount --add` (a `.m2` works the same; see `--help`).

three.js (MIT, `vendor/`) draws the preview.
