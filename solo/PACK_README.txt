Open Vanilla Solo
============

Play Open Vanilla offline on this PC: your own private world server, with playerbots, the Classic+
content and the same game client and addons you use on the live realm. The launcher's
PLAY SOLO button runs all of it in the background; you never need to open this folder.

Characters you make in Solo stay on this PC. They can't be moved to the live realm, and live
characters can't be brought here.

What is in this folder
----------------------
  bin\                 the world server (mangosd.exe, CMaNGOS classic with PlayerBots and
                       Open Vanilla's server hooks) and the login server (realmd.exe)
  bin\tools\           the map extractors (see below)
  mariadb\             a portable MariaDB database server (no installer, no service)
  db\                  the starting databases: the Classic+ world, empty character and
                       account databases
  sql\                 the Classic+ world changes, the same files the live realm runs
  conf\                the settings templates the launcher fills in
  tools\               Open Vanilla's server DBC fix-ups (starting gear and weapon skills for the
                       Classic+ race and class pairs)
  pack.json            what is in this pack, with a SHA-256 for every file

Made on your PC (never replaced by an update)
---------------------------------------------
  data\                your solo database: characters, the local account, bots
  gamedata\            maps extracted from YOUR game client (dbc, maps, vmaps, mmaps)
  etc\                 the settings in use, rewritten on every launch
  custom\              your own setting changes: e.g. custom\aiplayerbot.conf with the line
                       AiPlayerbot.MaxRandomBots = 200   (same "Key = Value" form)
  logs\                server logs (Server.log, Realmd.log, mariadb.err, extract.log)
  state.json           the local passwords and versions (keep it private)

The local account
-----------------
The launcher signs you in automatically. With the stock Vanilla client, type
account SOLO and password SOLO. The servers only listen on 127.0.0.1, so nobody else
can connect to them.

Map data and the extractors
---------------------------
No Blizzard game files are in this pack. The world server needs map data made from your own
Vanilla client. The first time you play solo the launcher looks for map data you already have
(solo\gamedata, the client folder, a local SPP or Open Vanilla server) and, when there is none,
runs the extractors on your client with a progress bar (about 10-20 minutes, once):

  bin\tools\ad.exe              DBC files and terrain maps     ad.exe -i <client> -o <out>
  bin\tools\vmap_extractor.exe  building and object geometry   vmap_extractor.exe -d <client>\Data -o <out>
  bin\tools\vmap_assembler.exe  assembles the vmaps            vmap_assembler.exe <out>\Buildings <out>\vmaps
  bin\tools\MoveMapGen.exe      movement maps (optional)       MoveMapGen.exe --workdir <out>\ --offMeshInput offmesh.txt
                                + offmesh.txt, config.json         --configInputPath config.json --threads N --buildGameObjects

They are CMaNGOS's own extractors (contrib/extractor, contrib/vmap_extractor,
contrib/vmap_assembler, contrib/mmap), built at the same commit as the world server.
Movement maps are optional in Solo: without them creatures walk in straight lines. To make
them later (it takes an hour or more), run:  "Play Solo.bat" solo --mmaps

Ports (this PC only)
--------------------
  3724  login (realmd)      8085  world (mangosd)      3311  MariaDB      7879  SOAP (shutdown)
If another server on this PC already uses 3724 or 8085 (a local realm), stop it first.

Starting over
-------------
Close the launcher and delete solo\data to get a fresh world (your solo characters go too).
Delete solo\gamedata to extract the maps again.

Licences: CMaNGOS and PlayerBots (GPL-2.0), classic-db (GPL-3.0), MariaDB (GPL-2.0).
Source: https://github.com/cmangos, https://github.com/orionopenwow/OpenVanilla
World of Warcraft is a trademark of Blizzard Entertainment, Inc. Open Vanilla is not affiliated
with Blizzard Entertainment.
