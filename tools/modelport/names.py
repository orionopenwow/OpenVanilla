"""Animation names → AnimationData ids, and the fallbacks a ported model uses for clips it lacks."""
import re

from .animdata import ANIMS

BY_NAME = {re.sub(r"[^a-z0-9]", "", n.lower()): i for i, (n, _, _) in ANIMS.items()}

# Common names from Blender, Mixamo, Unity and asset stores.
SYNONYMS = {
    0: ["idle", "idle1", "idleloop", "breathe", "breathing", "rest", "tpose", "default", "survey", "look", "lookaround"],
    1: ["die", "dying", "death1"],
    4: ["walking", "walkforward", "walkcycle", "walkloop", "trot", "pace"],
    5: ["running", "runforward", "runcycle", "runloop", "gallop", "galloping", "canter", "lope"],
    143: ["sprinting", "dash", "fastrun"],
    13: ["walkback", "walkbackward", "walkingbackward", "backwards", "backward", "retreat"],
    11: ["strafeleft", "sidestepleft", "turnleft"],
    12: ["straferight", "sidestepright", "turnright"],
    37: ["jumpstart", "jumpup", "takeoff", "jumpbegin"],
    38: ["jumploop", "jumpair", "inair", "airborne", "midair"],
    39: ["jumpend", "jumpland", "land", "landing"],
    40: ["falling", "freefall"],
    41: ["swimidle", "treadwater", "floatidle"],
    42: ["swimming", "swimforward"],
    16: ["attack", "attack1", "bite", "claw", "kick", "strike", "melee", "punch", "stomp"],
    25: ["combatidle", "ready", "alert", "aggro", "battleidle"],
    9: ["hurt", "gethit", "damage", "wound", "flinch", "hitreact"],
    14: ["stunned", "dizzy"],
    2: ["cast", "spell", "magic"],
    74: ["roar", "howl", "scream", "growl", "neigh", "whinny"],
    94: ["rear", "rearup", "buck", "mountspecial"],
    130: ["special", "creaturespecial", "trick"],
    61: ["eat", "eating", "graze", "grazing"],
    97: ["sit", "sitting"],
    100: ["sleep", "sleeping", "lie", "liedown"],
    91: ["mount", "ride", "riding", "rider", "seated"],
    135: ["fly", "flying", "flap", "hover"],
    30: ["dodge", "evade"],
    20: ["parry", "block"],
    6: ["dead", "corpse"],
}
for _id, words in SYNONYMS.items():
    for w in words:
        BY_NAME.setdefault(w, _id)

LOOPING = {0, 4, 5, 6, 11, 12, 13, 25, 38, 40, 41, 42, 43, 44, 45, 91, 97, 100, 119, 120, 135, 143, 144, 193}

# What a model plays for a clip it lacks: tried in order, then AnimationData's own chain, then Stand.
PREFER = {
    5: [4], 4: [5], 143: [5, 4], 13: [4], 11: [4, 5], 12: [4, 5], 92: [5], 93: [5],
    41: [0], 42: [5, 4], 43: [42, 5], 44: [42, 5], 45: [42, 13, 4],
    38: [40, 0], 40: [38, 0], 37: [38, 0], 39: [0], 187: [39, 5],
    25: [0], 16: [17, 18], 17: [16], 18: [16], 57: [16], 58: [16], 130: [16, 94],
    94: [130, 74], 74: [55, 0], 6: [1], 135: [5],
}


def parse(name):
    """Clip name → (anim id, variation hint) or (None, None). ``[id]`` anywhere forces the id;
    ``Walk_2`` / ``Attack 02`` is a second variation of the same id."""
    m = re.search(r"\[(\d{1,3})\]", name or "")
    if m and int(m.group(1)) in ANIMS:
        return int(m.group(1)), 0
    raw = (name or "").split("|")[-1]
    raw = re.sub(r"^(armature|rig|root|metarig|skeleton|anim|animation|mixamo\.com|mixamo)[_\s|.:-]*", "", raw, flags=re.I)
    var = 0
    mv = re.search(r"[_\s.-]*0*(\d+)$", raw)
    key = re.sub(r"[^a-z0-9]", "", raw.lower())
    if key in BY_NAME:
        return BY_NAME[key], 0
    if mv:
        base = re.sub(r"[^a-z0-9]", "", raw[: mv.start()].lower())
        if base in BY_NAME:
            var = max(0, int(mv.group(1)) - 1)
            return BY_NAME[base], var
    # "Horse_Gallop_Fast" → try every word, longest first
    words = sorted(set(re.split(r"[^a-z0-9]+", raw.lower())) - {""}, key=len, reverse=True)
    for w in words:
        if w in BY_NAME:
            return BY_NAME[w], 0
    return None, None


def anim_name(i):
    return ANIMS.get(i, (f"Anim{i}", 0, 0))[0]


def playable_lookup(owned, rows=203):
    """PlayableAnimationLookup rows: (resolved id, flags) for every requested id 0..rows-1."""
    out = []
    for i in range(rows):
        if i in owned:
            out.append((i, 0))
            continue
        hit = None
        for j in PREFER.get(i, []):
            if j in owned:
                hit = (j, 0)
                break
        if hit is None:
            seen, j, flags = {i}, i, 0
            while True:
                _, fb, fl = ANIMS.get(j, ("", 0, 0))
                if fb in seen or fb not in ANIMS:
                    break
                seen.add(fb)
                flags = fl if j == i else flags
                j = fb
                if j in owned:
                    hit = (j, flags & 0x30)
                    break
        out.append(hit or (0, 0))
    return out
