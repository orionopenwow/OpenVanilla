# Forge table schemas

`gen_schemas.py` makes `crates/forge-core/schemas/*.json`, the table layouts the Data editor uses:

| Output | Source | Licence of the source |
|---|---|---|
| `world.json` (CMaNGOS world tables) | `sql/base/mangos.sql` from [cmangos/mangos-classic](https://github.com/cmangos/mangos-classic) | GPL-2.0 (only names, types and defaults are taken) |
| `dbc.json` (1.12.1 client DBCs) | `dbd/*.dbd`, copies of [WoWDBDefs](https://github.com/wowdev/WoWDBDefs) definitions | CC BY-SA 4.0, © the WoWDBDefs contributors; `dbc.json` is a derived work under the same licence |

To refresh: download `mangos.sql`, update the `.dbd` files, and run `python3 gen_schemas.py path/to/mangos.sql`.
The layouts are checked against a real 1.12.1 client by `FORGE_REAL_DBC=<dir> cargo test real_dbc -- --ignored`.
