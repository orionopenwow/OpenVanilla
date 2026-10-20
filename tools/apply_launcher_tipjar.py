"""Adds the tip jar to the desktop launcher (launcher/openvanilla_launcher.py + launcher_art.py). Idempotent.

- A heart medallion in the left rail (above Settings) and a small SUPPORT THE REALM button above
  JOIN THE DISCORD on Home, both opening a Support page.
- The Support page: the tip jar art, Tip with crypto / Tip with card or PayPal, what supporters get,
  and the fine print. Links come from links.txt: DONATE_CRYPTO_URL and DONATE_CARD_URL (https only);
  empty = the buttons say tips open at launch.
Usage: python apply_launcher_tipjar.py <launcher folder>
"""
import os
import sys

MARK = "def page_support(self):"

HEART_ICON = '''    elif name == "heart":
        cx = s / 2
        pts = []
        for i in range(64):
            t = i / 64 * 2 * math.pi
            x = 16 * math.sin(t) ** 3
            y = -(13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))
            pts.append((cx + x * s * 0.024, s * 0.50 + y * s * 0.024))
        d.polygon(pts, outline=c, width=w)

'''

LINKS = '''    if "DONATE_CRYPTO_URL" in overrides:
        comm["donate_crypto"] = overrides["DONATE_CRYPTO_URL"]
    if "DONATE_CARD_URL" in overrides:
        comm["donate_card"] = overrides["DONATE_CARD_URL"]
'''

PAGE = '''    def page_support(self):
        """The tip jar: same words and art as the website's, with the two links from links.txt."""
        x, y, w, h = self.big_panel("SUPPORT THE REALM", "heart")
        comm = self.community_links()
        lw = 470
        # left: the jar art, framed, and what supporters get under it
        jar = os.path.join(ASSETS, "support_jar.webp")
        try:
            im = Image.open(jar).convert("RGBA")
            ih = round(im.height * lw / im.width)
            im = im.resize((lw, ih), Image.Resampling.LANCZOS)
            mask = Image.new("L", im.size, 0)
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, lw - 1, ih - 1], radius=12, fill=255)
            im.putalpha(mask)
            ImageDraw.Draw(im).rounded_rectangle([0, 0, lw - 1, ih - 1], radius=12, outline=(150, 116, 52, 255), width=2)
            self.cv.create_image(x, y, anchor="nw", image=self.img("support_jar", im), tags="page")
        except OSError:
            ih = 0
        py = y + ih + 18
        self.shadow_text(x, py, "WHAT SUPPORTERS GET", 10, GOLD)
        perks = ("A Supporter role in the Discord, and your name on the supporters wall if you'd like",
                 "A vote on what gets built next",
                 "Community goals unlock rewards for everyone when they're met")
        py += 22
        for p in perks:
            self.cv.create_text(x + 4, py, anchor="nw", text="\\u2022", fill=GOLD_DIM, font=font(10, "bold"), tags="page")
            t = self.cv.create_text(x + 20, py, anchor="nw", text=p, fill=TEXT, font=font(9), width=lw - 24, tags="page")
            bb = self.cv.bbox(t)
            py = (bb[3] if bb else py + 18) + 6

        # right: the pitch and the two tip buttons
        rx, rw = x + lw + 40, w - lw - 40
        self.cv.create_image(rx, y + 16, anchor="w", image=self.img("support_title", art.emboss_text("Keep the realm running", 22, "#f3d179")),
                             tags="page")
        body = ("Open Vanilla is free and built by volunteers. Tips pay for hosting first, then fixes and new features, "
                "and every one gets a public receipt from Orion.")
        t = self.cv.create_text(rx, y + 44, anchor="nw", text=body, fill=TEXT, font=font(10), width=rw, tags="page")
        bb = self.cv.bbox(t)
        by = (bb[3] if bb else y + 100) + 22
        crypto, card = safe_url(comm.get("donate_crypto")), safe_url(comm.get("donate_card"))

        def tip(url):
            if not safe_open(url or ""):
                self.notice("Tips open at launch; nothing is charged until then.", GOLD, 4.0)

        self.pill_button(rx, by, rw, 40, "TIP WITH CRYPTO", lambda: tip(crypto), style="gold", size=10, icon="heart")
        self.cv.create_text(rx + rw // 2, by + 54, text="Bitcoin \\u00b7 Lightning \\u00b7 USDC", fill=MUTED, font=font(8), tags="page")
        by += 72
        self.pill_button(rx, by, rw, 40, "TIP WITH CARD OR PAYPAL", lambda: tip(card), style="ghost", size=10, icon="link")
        self.cv.create_text(rx + rw // 2, by + 54, text="One-time or monthly", fill=MUTED, font=font(8), tags="page")
        by += 84
        self.cv.create_line(rx + 30, by, rx + rw - 30, by, fill="#4a3b22", tags="page")
        fine = ("Tips never buy power, items or game time." if (crypto or card) else
                "Tips open at launch; nothing is charged until then. Tips never buy power, items or game time.")
        self.cv.create_text(rx + rw // 2, by + 14, anchor="n", text=fine, fill=MUTED, font=font(8), width=rw, justify="center", tags="page")
        portal = comm.get("portal")
        if portal:
            self.link_text(rx + rw // 2, by + 56, "See where the money goes \\u2192", lambda: safe_open(portal), size=9, anchor="center")

'''


def patch(path, edits):
    s = open(path, encoding="utf-8").read()
    for name, old, new, once in edits:
        if new in s:
            continue
        assert old in s, f"{os.path.basename(path)}: anchor for {name} not found"
        s = s.replace(old, new, 1)
    open(path, "w", encoding="utf-8", newline="").write(s)


def main(d):
    lp = os.path.join(d, "openvanilla_launcher.py")
    if MARK in open(lp, encoding="utf-8").read():
        print(f"{lp}: already has the tip jar")
        return
    ap = os.path.join(d, "launcher_art.py")
    a_old = '    elif name == "plus":\n'
    patch(ap, [("heart icon", a_old, HEART_ICON + a_old, True)])

    rail_old = '        self._rail_medallion("settings", WIN_H - 104, "settings", None, lambda: self.show_page("settings"), tip="Settings")\n'
    rail_new = ('        self._rail_medallion("support", WIN_H - 160, "heart", None, lambda: self.show_page("support"), tip="Support the realm")\n'
                + rail_old)
    act_old = '{"addrealm": "servers", "settings": "settings", "help": "help"}'
    act_new = '{"addrealm": "servers", "support": "support", "settings": "settings", "help": "help"}'
    home_old = '''        self.pill_button(WIN_W - 34 - pw, by - 48, pw, 32, "JOIN THE DISCORD",
                         lambda: safe_open(self.community_links().get("discord") or ""), style="discord", size=8, icon="discord")
'''
    home_new = home_old + '''        # SUPPORT THE REALM: the tip jar, above JOIN THE DISCORD
        self.pill_button(WIN_W - 34 - pw, by - 88, pw, 32, "SUPPORT THE REALM", lambda: self.show_page("support"),
                         style="ghost", size=8, icon="heart")
'''
    links_old = '    if "GITHUB_REPO" in overrides:\n'
    page_old = '    def page_help(self):\n'
    imp_old = 'from PIL import Image, ImageTk\n'
    edits = [("rail", rail_old, rail_new, True), ("rail active", act_old, act_new, True), ("home button", home_old, home_new, True),
             ("links", links_old, LINKS + links_old, True), ("page", page_old, PAGE + page_old, True)]
    s = open(lp, encoding="utf-8").read()
    if "ImageDraw" not in s.split("class Launcher")[0]:
        edits.append(("import", imp_old, 'from PIL import Image, ImageDraw, ImageTk\n', True))
    patch(lp, edits)

    lt = os.path.join(d, "links.txt")
    if os.path.exists(lt):
        t = open(lt, encoding="utf-8").read()
        if "DONATE_CRYPTO_URL" not in t:
            nl = "\r\n" if "\r\n" in t else "\n"
            add = (f"{nl}# --- Tip jar (the launcher's Support page) ---{nl}"
                   f"# A BTCPay store page and a Ko-fi / GitHub Sponsors page (https only). Empty = 'tips open at launch'.{nl}"
                   f"DONATE_CRYPTO_URL ={nl}DONATE_CARD_URL ={nl}")
            open(lt, "w", encoding="utf-8", newline="").write(t.rstrip("\r\n") + nl + add)
    print(f"{lp}: tip jar added")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__)))
