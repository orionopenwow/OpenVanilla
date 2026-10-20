"""Tip jar polish (run after apply_support.py and apply_support_art.py). Idempotent.

- Hides the dollar goals on the Realm Levels (the levels and what they pay for stay).
- Frames the tip jar, the gentle prompt and the levels box with the site's gold filigree corners and divider.
- Switches the tip jar, prompt and community strip to a rounded sans (Nunito).
"""
import re
import sys

MARK = "/* ===== Tip jar frame and rounded type (apply_support_v2.py) ===== */"
FONT_LINK = ('  <link href="https://fonts.googleapis.com/css2?family=Nunito:wght@500;600;700;800;900&display=swap" '
             'rel="stylesheet">\n')

CSS = MARK + r"""
    .ow-jar, #owNudge, .ow-community, #owSupportPill { font-family: 'Nunito', 'Arial Rounded MT Bold', Arial, sans-serif; }
    .ow-jar h3, .ow-goals h5, #owNudge b, .ow-community h4 { font-family: 'Nunito', 'Arial Rounded MT Bold', Arial, sans-serif; font-weight: 900; letter-spacing: .2px; }
    .ow-jar h3 { font-size: 1.45rem; }
    .ow-jar p, .ow-jar ul { font-size: .9rem; }
    .ow-jar { border-radius: 14px; box-shadow: inset 0 0 0 1px #966f2c, 0 20px 60px rgba(0,0,0,.8); }
    .ow-jar-art { height: 128px; border-radius: 12px 12px 0 0; overflow: hidden; border-bottom: 0; position: relative; }
    .ow-jar-art::after { content: ''; position: absolute; left: 0; right: 0; bottom: -2px; height: 21px;
      background: url('assets/orion/support_divider.png') center / auto 100% no-repeat; }
    .ow-jar-btns a, .ow-goals { border-radius: 10px; }
    .ow-jar-btns a { font-weight: 800; }
    #owNudge { border-radius: 14px; }
    #owNudge .row button, .ow-community button { border-radius: 8px; }
    .ow-frame { position: relative; }
    .ow-frame::before { content: ''; position: absolute; inset: 3px; pointer-events: none; z-index: 3;
      background-image: url('assets/corner_filigree_tl.png'), url('assets/corner_filigree_tr.png'),
        url('assets/corner_filigree_bl.png'), url('assets/corner_filigree_br.png');
      background-position: top left, top right, bottom left, bottom right; background-size: 44px 38px; background-repeat: no-repeat; }
    .ow-goals { position: relative; padding: .8rem .95rem .7rem; }
    .ow-goals::before { content: ''; position: absolute; inset: -1px; pointer-events: none;
      background-image: url('assets/ui_corner_tl.png'), url('assets/ui_corner_tr.png'), url('assets/ui_corner_bl.png'), url('assets/ui_corner_br.png');
      background-position: top left, top right, bottom left, bottom right; background-size: 16px 26px; background-repeat: no-repeat; }
    .ow-goal { grid-template-columns: 22px 1fr; font-size: .82rem; padding: .22rem 0; }
    .ow-jar .ow-jar-btns { margin-bottom: .85rem; }
    .ow-jar ul { margin-bottom: .6rem; }
    #owNudge.ow-frame::before { background-size: 30px 26px; }
    #owNudge b { padding-right: 18px; }
    .ow-jar .ow-x { z-index: 5; top: .85rem; right: 1.05rem; width: 30px; height: 30px; border-radius: 50%; background: rgba(5,8,14,.7); line-height: 1; }
    .ow-goal small { font-size: .74rem; }
    .ow-jar .ow-fine { border-top: 0; padding-top: 1.1rem; background: url('assets/orion/support_divider.png') top center / 80% auto no-repeat; }
"""


def apply(path):
    s = open(path, encoding="utf-8").read()
    if MARK in s:
        print(f"{path}: already polished")
        return
    assert 'class="ow-jar-art"' in s, "run apply_support_art.py first"
    # costs out: the goal amounts in the tip jar and the bucket amounts in the hidden Starfall section
    s, n = re.subn(r'<em>\$[\d,]+/mo</em>', '', s)
    s = re.sub(r'(<li><b>[^<:]+) \(\$[\d,]+/mo\):</b>', r'\1:</b>', s)
    s = s.replace('<h5>Realm Levels <span>monthly goals, filled in order</span></h5>', '<h5>Realm Levels <span>filled in order</span></h5>')
    s = s.replace('aria-label="Monthly realm goals"', 'aria-label="Realm levels"')
    # frames
    s = s.replace('<div class="ow-jar">', '<div class="ow-jar ow-frame">', 1)
    s = s.replace('<div id="owNudge" role="status">', '<div id="owNudge" class="ow-frame" role="status">', 1)
    # font
    if "family=Nunito" not in s:
        i = s.index("</head>")
        s = s[:i] + FONT_LINK + s[i:]
    i = s.index("</style>")
    s = s[:i] + "    " + CSS + "  " + s[i:]
    open(path, "w", encoding="utf-8", newline="").write(s)
    print(f"{path}: polished ({n} amounts hidden)")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        apply(p)
