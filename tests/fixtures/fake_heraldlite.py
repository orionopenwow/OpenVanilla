"""A stand-in for `heraldlite autopilot` (tests only): writes a short run log in the real format,
then exits with the code in FAKE_HL_EXIT (default 0)."""
import json
import os
import sys
import time

args = sys.argv[1:]
log = args[args.index("--log") + 1]
assert os.environ.get("HL_PASS"), "password must come in the environment"
rows = [
    {"event": "start", "action": "start", "result": "12 steps"},
    {"event": "decision", "step": 3, "action": "Ranged", "result": ""},
    {"event": "outcome", "step": 3, "action": "kill", "result": "299 (0xf130000123)"},
    {"event": "outcome", "step": 3, "action": "xp", "result": "+45 (kill)"},
    {"event": "outcome", "step": 3, "action": "loot", "result": "17 copper"},
    {"event": "outcome", "step": 4, "action": "quest rewarded", "result": "quest 33 (+120 xp, 75 copper)"},
    {"event": "outcome", "step": 4, "action": "level up", "result": "level 3"},
    {"event": "outcome", "step": 5, "action": "died", "result": ""},
    {"event": "summary", "step": 5, "action": "", "result": "", "summary": {"minutes": 4.2, "kills": 1, "deaths": 1,
                                                                             "level_start": 2, "level_end": 3}},
]
with open(log, "w") as f:
    for i, r in enumerate(rows):
        r.update(t=i, min=i / 60, pos=[-8900.0, -120.0, 82.0], level=3 if i >= 6 else 2, xp=100 + i, hp=80, max_hp=100, mana=60)
        f.write(json.dumps(r) + "\n")
        f.flush()
        time.sleep(0.01)
sys.exit(int(os.environ.get("FAKE_HL_EXIT", "0")))
