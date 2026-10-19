"""Adds art and monthly realm goals to the tip jar (run after apply_support.py). Idempotent.

- Tip jar: a header picture (assets/orion/support_jar.webp) and the five Realm Levels with monthly dollar goals.
- Gentle prompt: Orion's sigil (assets/orion/support_sigil.webp).
- "Created for free by the community" strip: a constellation band behind it (assets/orion/support_strip.webp).
- Starfall Giving buckets (hidden section): the same dollar goals.
Change the goals in LEVELS below and re-run on a fresh copy, or edit the numbers in the HTML directly.
"""
import sys

MARK = 'class="ow-jar-art"'
# (name, what it pays for, this bucket per month, running total per month)
LEVELS = [
    ("Base Hosting", "the vanilla realms and this site", 60, 60),
    ("Orion Brain Fuel", "Orion's bug triage and the Discord bot", 90, 150),
    ("Worker Bounties", "paid fixes and community pull requests", 250, 400),
    ("Hardware Scaling", "a high-tick raid and PvP node", 200, 600),
    ("Orion Network Cloud", "player-hosted worlds", 400, 1000),
]

CSS = r"""
    /* ===== Tip jar art and realm goals (apply_support_art.py) ===== */
    .ow-jar { padding-top: 0; overflow: hidden; max-height: calc(100vh - 32px); overflow-y: auto; }
    .ow-jar-art { margin: 0 -1.5rem 1rem; height: 150px; background: #12142a; border-bottom: 1px solid #5e431a; }
    .ow-jar-art img { width: 100%; height: 100%; object-fit: cover; object-position: 62% 50%; display: block; }
    .ow-jar .ow-x { z-index: 2; color: #fff; text-shadow: 0 1px 4px #000; }
    .ow-goals { margin: 0 0 1rem; border: 1px solid var(--border-edge); background: rgba(5,8,14,.55); padding: .65rem .8rem .55rem; }
    .ow-goals h5 { margin: 0 0 .45rem; font-family: var(--font-display); color: var(--gold-bright); font-size: .82rem; letter-spacing: .4px; display: flex; justify-content: space-between; }
    .ow-goals h5 span { font-family: var(--font-body); color: var(--text-muted); font-weight: 500; font-size: .7rem; letter-spacing: 0; }
    .ow-goal { display: grid; grid-template-columns: 22px 1fr auto; gap: .5rem; align-items: center; padding: .28rem 0; font-size: .76rem; color: #cbd5e1; border-top: 1px solid rgba(255,255,255,.05); }
    .ow-goal:first-of-type { border-top: 0; }
    .ow-goal i { width: 18px; height: 18px; display: grid; place-items: center; font-style: normal; font-size: .62rem; font-weight: 800; color: #0b0f17;
      clip-path: polygon(25% 3%, 75% 3%, 100% 50%, 75% 97%, 25% 97%, 0 50%); background: var(--c); }
    .ow-goal b { color: #fff; font-weight: 700; }
    .ow-goal small { display: block; color: var(--text-muted); font-size: .68rem; }
    .ow-goal em { font-style: normal; color: var(--gold-bright); font-weight: 700; white-space: nowrap; }
    .ow-community { position: relative; border-top: 0; background: linear-gradient(180deg, rgba(11,15,23,.55), rgba(11,15,23,.8)), url("assets/orion/support_strip.webp") center / cover no-repeat;
      border: 1px solid var(--border-edge); border-left: 0; border-right: 0; padding: 1.8rem 1.5rem; }
    .ow-community h4 { text-shadow: 0 2px 10px #000; }
    .ow-community p { color: #cbd5e1; text-shadow: 0 1px 6px #000; }
    #owNudge { padding-left: 4.9rem; min-height: 92px; }
    #owNudge .ow-sigil { position: absolute; left: .55rem; top: .7rem; width: 64px; height: 64px; }
"""


def goals_html():
    cols = ["#60a5fa", "#a78bfa", "#e9c46a", "#f08a6a", "#6ee7b7"]
    rows = []
    for i, (name, what, step, total) in enumerate(LEVELS):
        rows.append(f'        <div class="ow-goal" style="--c: {cols[i]};"><i>{i + 1}</i><div><b>{name}</b><small>{what}</small></div>'
                    f'<em>${total:,}/mo</em></div>')
    return ('      <div class="ow-goals" aria-label="Monthly realm goals">\n'
            '        <h5>Realm Levels <span>monthly goals, filled in order</span></h5>\n' + "\n".join(rows) + "\n      </div>\n")


def apply(path):
    s = open(path, encoding="utf-8").read()
    if MARK in s:
        print(f"{path}: already has the tip jar art")
        return
    assert 'id="owTipJar"' in s, "run apply_support.py first"
    i = s.index("</style>")
    s = s[:i] + CSS + "  " + s[i:]
    x = '<button class="ow-x" type="button" aria-label="Close" onclick="closeSupportModal()">×</button>\n'
    assert x in s
    s = s.replace(x, x + '      <div class="ow-jar-art"><img src="assets/orion/support_jar.webp" width="920" height="340" alt="A glass jar of starlight '
                  'beneath the Orion constellation, with five glowing gems climbing toward it" loading="lazy"></div>\n', 1)
    btn_end = '<small>One-time or monthly</small></a>\n      </div>\n'
    assert btn_end in s
    s = s.replace(btn_end, btn_end + goals_html(), 1)
    n = '<div id="owNudge" role="status">\n'
    assert n in s
    s = s.replace(n, n + '    <img class="ow-sigil" src="assets/orion/support_sigil.webp" width="64" height="64" alt="">\n', 1)
    # Starfall Giving buckets (hidden section) get the same goals.
    for name, what, step, total in LEVELS:
        old = f"<li><b>{name}:</b> "
        if old in s:
            s = s.replace(old, f"<li><b>{name} (${step:,}/mo):</b> ", 1)
    open(path, "w", encoding="utf-8", newline="").write(s)
    print(f"{path}: tip jar art and goals added")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        apply(p)
