"""Restyles the realm's loading box (openvanilla.js boot overlay) in Open Vanilla's look. Idempotent.
Usage: python apply_boot_style.py <openvanilla.js> [<openvanilla.js> ...]   (boot_css.txt beside this script)"""
import os, sys
MARK = "OW Cinzel"
css = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "boot_css.txt"), encoding="utf-8").read()
for p in sys.argv[1:]:
    s = open(p, encoding="utf-8").read()
    if MARK in s:
        print(p, "already styled"); continue
    a = s.index("    #wenilla-boot .box { position: relative; margin-top: 52vh;")
    end = '    #wenilla-boot .stage::after { content: "Preparing your adventure…"; font-size: 15px; }\n'
    b = s.index(end) + len(end)
    s = s[:a] + css + s[b:]
    open(p, "w", encoding="utf-8", newline="").write(s); print(p, "styled")
