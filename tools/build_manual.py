#!/usr/bin/env python3
"""Build the Open Vanilla Manual: docs/manual/*.md  ->  www/manual/*.html

    python tools/build_manual.py          build every chapter
    python tools/build_manual.py --check  build, then fail if any manual link or anchor is broken

Source format (a small, strict Markdown so the pages are predictable):
  front matter      first lines `key: value` until a blank line: slug, title, kicker, summary
  ## Heading {#id}  a section; the id is the deep link (manual/<slug>.html#<id>). Without {#id} it is
                    made from the heading text.
  ### Heading       a sub-heading inside a section (gets an id too)
  paragraphs, - bullets, 1. numbered steps, ``` code blocks ```, | tables |,
  > **Note:** ...   a callout (> **Warning:** or > **Never:** for the warning styles)
  <div ...>         a raw HTML block, up to the next blank line (used sparingly)
  **bold**, `code`, [text](link). Links to other chapters: [text](launcher.html#settings).

Outputs: one page per chapter, index.html (contents), links.json (every deep link: what the site,
launcher and Herald link to) and search.json (the sidebar search).
"""
import html
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "docs", "manual")
OUT = os.path.join(ROOT, "www", "manual")


def slugify(text):
    s = re.sub(r"<[^>]+>", "", text).lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s or "section"


def inline(text):
    """Escape, then apply `code`, **bold**, *italic*, [links](...)."""
    parts = re.split(r"(`[^`]+`)", text)
    out = []
    for p in parts:
        if p.startswith("`") and p.endswith("`") and len(p) > 1:
            out.append("<code>" + html.escape(p[1:-1]) + "</code>")
            continue
        p = html.escape(p, quote=False)
        p = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", lambda m: f'<a href="{m.group(2)}"'
                   + (' target="_blank" rel="noopener"' if m.group(2).startswith("http") else "")
                   + f">{m.group(1)}</a>", p)
        p = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", p)
        p = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", p)
        out.append(p)
    return "".join(out)


def parse(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    meta, i = {}, 0
    while i < len(lines) and lines[i].strip():
        k, _, v = lines[i].partition(":")
        meta[k.strip()] = v.strip()
        i += 1
    body = lines[i:]
    sections, cur = [], None          # [{id,title,html:[]}]
    intro = []
    seen = set()

    def target():
        return cur["html"] if cur else intro

    def uid(base):
        s, n = base, 2
        while s in seen:
            s, n = f"{base}-{n}", n + 1
        seen.add(s)
        return s

    j = 0
    while j < len(body):
        ln = body[j]
        st = ln.strip()
        if not st:
            j += 1
            continue
        m = re.match(r"^(#{2,3})\s+(.*?)(?:\s*\{#([a-z0-9-]+)\})?\s*$", st)
        if m:
            level, title, sid = len(m.group(1)), m.group(2), m.group(3)
            sid = uid(sid or slugify(title))
            if level == 2:
                cur = {"id": sid, "title": title, "html": [], "subs": []}
                sections.append(cur)
            else:
                target().append(f'<h3 id="{sid}">{inline(title)} <a class="anchor" href="#{sid}" aria-label="Link to this">#</a></h3>')
                if cur:
                    cur["subs"].append((sid, title))
            j += 1
            continue
        if st.startswith("<"):                      # raw HTML block (the contents page's cards)
            raw = []
            while j < len(body) and body[j].strip():
                raw.append(body[j])
                j += 1
            target().append("\n".join(raw))
            continue
        if st.startswith("```"):
            k = j + 1
            code = []
            while k < len(body) and not body[k].strip().startswith("```"):
                code.append(body[k])
                k += 1
            target().append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")
            j = k + 1
            continue
        if st.startswith("|"):
            rows = []
            while j < len(body) and body[j].strip().startswith("|"):
                rows.append([c.strip() for c in body[j].strip().strip("|").split("|")])
                j += 1
            head, rest = rows[0], [r for r in rows[1:] if not all(re.fullmatch(r":?-{2,}:?", c) for c in r)]
            t = ['<div class="tbl"><table><thead><tr>' + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr></thead><tbody>"]
            for r in rest:
                t.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
            t.append("</tbody></table></div>")
            target().append("".join(t))
            continue
        if st.startswith(">"):
            q = []
            while j < len(body) and body[j].strip().startswith(">"):
                q.append(body[j].strip()[1:].strip())
                j += 1
            text = " ".join(q)
            kind = "warn" if re.match(r"\*\*(Warning|Careful)", text) else "bad" if text.startswith("**Never") else ""
            target().append(f'<div class="callout {kind}"><p>{inline(text)}</p></div>')
            continue
        if re.match(r"^(-|\d+\.)\s", st):
            ordered = bool(re.match(r"^\d+\.", st))
            items = []
            while j < len(body) and body[j].strip() and (re.match(r"^(-|\d+\.)\s", body[j].strip()) or body[j].startswith("   ")):
                s2 = body[j].strip()
                if re.match(r"^(-|\d+\.)\s", s2):
                    items.append(re.sub(r"^(-|\d+\.)\s+", "", s2))
                else:
                    items[-1] += " " + s2
                j += 1
            tag = "ol" if ordered else "ul"
            cls = ' class="steps"' if ordered else ""
            target().append(f"<{tag}{cls}>" + "".join(f"<li>{inline(x)}</li>" for x in items) + f"</{tag}>")
            continue
        para = []
        while j < len(body) and body[j].strip() and not re.match(r"^(#{2,3}\s|```|\||>|-\s|\d+\.\s)", body[j].strip()):
            para.append(body[j].strip())
            j += 1
        target().append(f"<p>{inline(' '.join(para))}</p>")
    return meta, intro, sections


PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{title} · Open Vanilla Manual</title>
  <meta name="description" content="{summary}">
  <meta property="og:title" content="{title} · Open Vanilla Manual">
  <meta property="og:description" content="{summary}">
  <link rel="icon" href="../favicon.ico">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Albert+Sans:wght@400;600;700&family=Belgrano&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="manual.css">
</head>
<body>
  <div class="wrap">
    <header class="top">
      <a class="home" href="../index.html"><img src="../assets/openvanilla_logo_nav.png" alt="" class="mark">Open Vanilla</a>
      <a class="pill" href="index.html">THE MANUAL</a>
    </header>
    <div class="layout">
      <nav class="toc" aria-label="Manual">
        <input class="search" type="search" placeholder="Search the manual" aria-label="Search the manual">
        <ol class="results" hidden></ol>
        <details class="chapters-box" open>
          <summary class="toc-title">Chapters</summary>
          <ol class="chapters">
{toc}
          </ol>
        </details>
      </nav>
      <article>
        <p class="kicker">{kicker}</p>
        <h1>{title}</h1>
        <p class="lead">{summary}</p>
{intro}
{onpage}
{body}
        <nav class="pager">{prev}{next}</nav>
        <footer>Open Vanilla is an independent, free fan project, not affiliated with or endorsed by Blizzard Entertainment.
          World of Warcraft is a trademark of Blizzard Entertainment, Inc. Something wrong or missing on this page?
          <a href="contributing.html#fix-the-manual">Fix the manual</a>.</footer>
      </article>
    </div>
  </div>
  <script src="manual.js" defer></script>
</body>
</html>
"""


def build(check=False):
    files = sorted(f for f in os.listdir(SRC) if f.endswith(".md"))
    chapters = []
    for f in files:
        meta, intro, sections = parse(os.path.join(SRC, f))
        meta.setdefault("slug", slugify(re.sub(r"^\d+-", "", f[:-3])))
        chapters.append((meta, intro, sections))
    os.makedirs(OUT, exist_ok=True)
    links, search = {}, []
    for n, (meta, intro, sections) in enumerate(chapters):
        slug = meta["slug"]
        toc = []
        for m2, _, secs in chapters:
            here = m2["slug"] == slug
            toc.append(f'          <li><a href="{m2["slug"]}.html"' + (' class="on" aria-current="page"' if here else "") + f'>{inline(m2["title"])}</a>')
            if here and secs:
                toc.append("            <ol class=\"secs\">" + "".join(f'<li><a href="#{s["id"]}">{inline(s["title"])}</a></li>' for s in secs) + "</ol>")
            toc.append("          </li>")
        body = []
        for s in sections:
            body.append(f'        <section class="ch" id="{s["id"]}">\n          <h2>{inline(s["title"])} <a class="anchor" href="#{s["id"]}" aria-label="Link to this">#</a></h2>\n          '
                        + "\n          ".join(s["html"]) + "\n        </section>")
            links[f"{slug}#{s['id']}"] = {"url": f"manual/{slug}.html#{s['id']}", "title": re.sub(r"<[^>]+>", "", s["title"]), "chapter": meta["title"]}
            for sid, st in s["subs"]:
                links[f"{slug}#{sid}"] = {"url": f"manual/{slug}.html#{sid}", "title": st, "chapter": meta["title"]}
            text = re.sub(r"<[^>]+>", " ", " ".join(s["html"]))
            search.append({"u": f"{slug}.html#{s['id']}", "t": re.sub(r"<[^>]+>", "", s["title"]), "c": meta["title"],
                           "x": re.sub(r"\s+", " ", html.unescape(text)).strip()[:600]})
        links[slug] = {"url": f"manual/{slug}.html", "title": meta["title"], "chapter": meta["title"]}
        onpage = ""
        if len(sections) > 2:
            onpage = '        <div class="onpage"><span>On this page</span>' + "".join(f'<a href="#{s["id"]}">{inline(s["title"])}</a>' for s in sections) + "</div>"
        prev = next_ = ""
        if n > 0:
            pm = chapters[n - 1][0]
            prev = f'<a class="prev" href="{pm["slug"]}.html"><span>Previous</span>{inline(pm["title"])}</a>'
        if n + 1 < len(chapters):
            nm = chapters[n + 1][0]
            next_ = f'<a class="next" href="{nm["slug"]}.html"><span>Next</span>{inline(nm["title"])}</a>'
        if "<!--contents-->" in "".join(intro):
            cards = []
            for m2, _, secs in chapters:
                if m2["slug"] == slug:
                    continue
                cards.append(f'<li><a href="{m2["slug"]}.html"><b>{inline(m2["title"])}</b></a><span>{html.escape(m2.get("summary", ""))}</span>'
                             + ('<span class="secl">' + " · ".join(f'<a href="{m2["slug"]}.html#{x["id"]}">{inline(x["title"])}</a>' for x in secs) + "</span>" if secs else "")
                             + "</li>")
            intro = [x.replace("<!--contents-->", '<ol class="contents">' + "".join(cards) + "</ol>") for x in intro]
        page = PAGE.format(title=html.escape(meta["title"]), kicker=html.escape(meta.get("kicker", "")),
                           summary=html.escape(meta.get("summary", "")), toc="\n".join(toc),
                           intro="\n".join("        " + x for x in intro), onpage=onpage, body="\n".join(body),
                           prev=prev, next=next_)
        open(os.path.join(OUT, f"{slug}.html"), "w", encoding="utf-8", newline="\n").write(page)
    json.dump(links, open(os.path.join(OUT, "links.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    json.dump(search, open(os.path.join(OUT, "search.json"), "w", encoding="utf-8"), ensure_ascii=False)
    print(f"built {len(chapters)} pages, {len(links)} deep links -> {os.path.relpath(OUT, ROOT)}")
    if check:
        return check_links()
    return 0


def check_links():
    """Every href inside the manual, and every manual/... link anywhere in www, must resolve."""
    www = os.path.dirname(OUT)
    ids = {}
    for f in os.listdir(OUT):
        if f.endswith(".html"):
            ids[f] = set(re.findall(r'id="([^"]+)"', open(os.path.join(OUT, f), encoding="utf-8").read()))
    bad = []
    def resolve(base_dir, href, here):
        page, _, frag = href.partition("#")
        path = os.path.normpath(os.path.join(base_dir, page)) if page else here
        if not os.path.exists(path):
            return False
        if frag and path.endswith(".html"):
            return frag in set(re.findall(r'id="([^"]+)"', open(path, encoding="utf-8", errors="replace").read()))
        return True

    for f in ids:
        here = os.path.join(OUT, f)
        for href in re.findall(r'(?:href|src)="([^"]+)"', open(here, encoding="utf-8").read()):
            if href.startswith(("http", "mailto:", "openvanilla:", "data:")):
                continue
            if not resolve(OUT, href, here):
                bad.append(f"{f}: {href}")
    for dirpath, _, names in os.walk(www):
        if os.path.abspath(dirpath).startswith(os.path.abspath(OUT)):
            continue
        for name in names:
            if not name.endswith(".html"):
                continue
            p = os.path.join(dirpath, name)
            for href in re.findall(r'href="((?:\.\./)*manual/[^"]+)"', open(p, encoding="utf-8", errors="replace").read()):
                page, _, frag = href.split("manual/", 1)[1].partition("#")
                if page not in ids or (frag and frag not in ids[page]):
                    bad.append(f"{os.path.relpath(p, www)}: {href}")
    for b in bad:
        print("BROKEN", b)
    print("links ok" if not bad else f"{len(bad)} broken links")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(build("--check" in sys.argv))
