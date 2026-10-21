#!/usr/bin/env python3
"""Build the website's www/legend.html from legend.src.html by inlining legend.js (no external scripts)."""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BEGIN, END = "/* @@LEGEND_JS_BEGIN */", "/* @@LEGEND_JS_END */"

with open(os.path.join(HERE, "legend.js"), encoding="utf-8") as f:
    lib = f.read().strip()
with open(os.path.join(HERE, "legend.src.html"), encoding="utf-8") as f:
    src = f.read()
if "</script" in lib.lower():
    raise SystemExit("legend.js must not contain </script")
start, end = src.index(BEGIN) + len(BEGIN), src.index(END)
out = src[:start] + "\n" + lib + "\n" + src[end:]
with open(os.path.join(HERE, "..", "www", "legend.html"), "w", encoding="utf-8") as f:
    f.write(out)
print("wrote www/legend.html (%d bytes)" % len(out.encode("utf-8")))
