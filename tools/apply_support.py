"""Gentle, typical donation touches for the Open Vanilla site. Idempotent: run on index.html and portal.html.

- Every "Support the realm" button opens a tip jar (crypto + card), not the old "disabled" toast.
- A "Created for free by the community" strip above the footer, crediting the projects Open Vanilla stands on.
- A small "Support" pill in the corner, and a one-time gentle prompt (after 45 s or most of the page,
  at most once every 21 days, never twice in a session, easy to dismiss).
Links come from links.txt: DONATE_CRYPTO_URL (e.g. the BTCPay store page) and DONATE_CARD_URL (Ko-fi /
GitHub Sponsors). Empty = the jar says tips open at launch.
"""
import sys

MARK = 'id="owTipJar"'

CSS = r"""
    /* ===== Tip jar, community strip, support pill (tools_apply_support.py) ===== */
    #owTipJar { position: fixed; inset: 0; z-index: 9000; display: none; place-items: center; background: rgba(3,5,9,.72); padding: 16px; }
    #owTipJar.open { display: grid; }
    .ow-jar { position: relative; width: min(460px, 100%); background: linear-gradient(180deg, #141a26, #0b0f17); border: 2px solid #5e431a;
      box-shadow: inset 0 0 0 1px #966f2c, 0 20px 60px rgba(0,0,0,.8); padding: 1.6rem 1.5rem 1.3rem; color: var(--text-main); }
    .ow-jar h3 { font-family: var(--font-display); color: var(--gold-bright); font-size: 1.35rem; margin: 0 0 .35rem; }
    .ow-jar p { font-size: .86rem; color: var(--text-muted); line-height: 1.5; margin: 0 0 1rem; }
    .ow-jar .ow-x { position: absolute; top: .55rem; right: .7rem; background: none; border: 0; color: var(--text-muted); font-size: 1.4rem; }
    .ow-jar-btns { display: grid; gap: .6rem; margin-bottom: 1rem; }
    .ow-jar-btns a { display: flex; justify-content: space-between; align-items: center; gap: 10px; padding: .8rem 1rem; text-decoration: none;
      color: #fff; font-weight: 700; font-size: .9rem; border: 1px solid rgba(212,167,66,.55); background: linear-gradient(180deg, #1b2230, #0e121a); }
    .ow-jar-btns a small { color: var(--text-muted); font-weight: 500; font-size: .74rem; }
    .ow-jar-btns a:hover { border-color: var(--gold-border-bright); }
    .ow-jar-btns a.off { opacity: .5; pointer-events: none; }
    .ow-jar ul { margin: 0 0 .9rem; padding-left: 1.1rem; font-size: .8rem; color: #cbd5e1; line-height: 1.6; }
    .ow-jar .ow-fine { font-size: .72rem; color: var(--text-muted); border-top: 1px solid var(--border-edge); padding-top: .7rem; margin: 0; }
    .ow-jar .ow-fine a { color: var(--gold-primary); }
    .ow-community { max-width: 1200px; margin: 2.5rem auto 0; padding: 1.4rem 1.5rem; text-align: center; border-top: 1px solid var(--border-edge); }
    .ow-community h4 { font-family: var(--font-display); color: var(--gold-bright); font-size: 1.05rem; margin: 0 0 .4rem; letter-spacing: .5px; }
    .ow-community p { font-size: .8rem; color: var(--text-muted); margin: 0 auto .8rem; max-width: 720px; line-height: 1.6; }
    .ow-community p a { color: var(--gold-primary); text-decoration: none; }
    .ow-community button { font-size: .78rem; padding: .5rem 1.1rem; }
    #owSupportPill { position: fixed; left: 14px; bottom: 14px; z-index: 8000; border: 1px solid rgba(212,167,66,.55); background: rgba(11,15,23,.92);
      color: var(--gold-bright); font: 700 .74rem var(--font-body); padding: .45rem .8rem; border-radius: 999px; letter-spacing: .3px;
      box-shadow: 0 4px 14px rgba(0,0,0,.5); }
    #owSupportPill:hover { border-color: var(--gold-border-bright); }
    #owNudge { position: fixed; left: 14px; bottom: 14px; z-index: 8001; width: min(330px, calc(100vw - 28px)); display: none;
      background: linear-gradient(180deg, #141a26, #0b0f17); border: 1px solid #5e431a; box-shadow: inset 0 0 0 1px #966f2c, 0 12px 34px rgba(0,0,0,.7);
      padding: .95rem 1rem .85rem; font-size: .8rem; color: #cbd5e1; line-height: 1.5; animation: owNudgeIn .45s ease both; }
    #owNudge.show { display: block; }
    #owNudge b { color: var(--gold-bright); font-family: var(--font-display); font-size: .92rem; display: block; margin-bottom: .2rem; }
    #owNudge .row { display: flex; gap: .5rem; margin-top: .65rem; }
    #owNudge .row button { flex: 1; font-size: .74rem; padding: .45rem .5rem; }
    #owNudge .later { background: none; border: 1px solid var(--border-edge); color: var(--text-muted); }
    @keyframes owNudgeIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: none; } }
"""

HTML = r"""
  <!-- Created for free by the community (tools_apply_support.py) -->
  <section class="ow-community" aria-label="Credits and support">
    <h4>Created for free by the community</h4>
    <p>Open Vanilla stands on open-source work by
      <a href="https://github.com/Arnesen/wenilla" target="_blank" rel="noopener noreferrer">wenilla (Arnesen)</a>,
      <a href="https://github.com/samwhosung/benilla" target="_blank" rel="noopener noreferrer">benilla (samwhosung)</a>,
      <a href="https://github.com/cmangos" target="_blank" rel="noopener noreferrer">CMaNGOS</a> and
      <a href="https://github.com/celguar/spp-classics-cmangos" target="_blank" rel="noopener noreferrer">SPP Classics (celguar)</a>,
      and on every tester, bug reporter and helper in the <a href="#" class="openvanilla-discord-link" target="_blank" rel="noopener noreferrer">Discord</a>.
      Nobody here is paid to make it. If it's given you a good evening in Azeroth, a tip keeps the realm online.</p>
    <button class="btn-gold-ornate" type="button" onclick="openSupportModal()">Support the realm</button>
  </section>

  <div id="owTipJar" role="dialog" aria-modal="true" aria-labelledby="owJarTitle" onclick="if (event.target === this) closeSupportModal()">
    <div class="ow-jar">
      <button class="ow-x" type="button" aria-label="Close" onclick="closeSupportModal()">×</button>
      <h3 id="owJarTitle">Keep the realm running</h3>
      <p>Open Vanilla is free and built by volunteers. Tips pay for hosting first, then fixes and new features, and every one gets a public receipt from Orion.</p>
      <div class="ow-jar-btns">
        <a id="owJarCrypto" href="#" target="_blank" rel="noopener noreferrer">Tip with crypto <small>Bitcoin · Lightning · USDC</small></a>
        <a id="owJarCard" href="#" target="_blank" rel="noopener noreferrer">Tip with card or PayPal <small>One-time or monthly</small></a>
      </div>
      <ul>
        <li>A <b>Supporter</b> role in the Discord, and your name on the supporters wall if you'd like</li>
        <li>A vote on what gets built next</li>
        <li>Community goals unlock rewards <b>for everyone</b> when they're met</li>
      </ul>
      <p class="ow-fine" id="owJarFine">Tips never buy power, items or game time. <a href="#orion">See where the money goes</a>.</p>
    </div>
  </div>
  <button id="owSupportPill" type="button" onclick="openSupportModal()" aria-label="Support Open Vanilla">♥ Support</button>
  <div id="owNudge" role="status">
    <b>Enjoying Open Vanilla?</b>
    It's free and made by the community. A small tip keeps the realm online for everyone.
    <div class="row">
      <button class="btn-gold-ornate" type="button" onclick="owNudgeClose(); openSupportModal()">Support</button>
      <button class="later" type="button" onclick="owNudgeClose()">Not now</button>
    </div>
  </div>
"""

JS = r"""
    // ===== Tip jar (tools_apply_support.py): DONATE_CRYPTO_URL / DONATE_CARD_URL in links.txt =====
    function owJarLinks() {
      var any = false;
      [['owJarCrypto', 'DONATE_CRYPTO_URL'], ['owJarCard', 'DONATE_CARD_URL']].forEach(function(p) {
        var a = document.getElementById(p[0]), u = String(openvanillaLinks[p[1]] || '').trim();
        if (!a) return;
        var ok = /^https:\/\//.test(u);
        a.href = ok ? u : '#';
        a.classList.toggle('off', !ok);
        any = any || ok;
      });
      var fine = document.getElementById('owJarFine');
      if (fine && !any) fine.innerHTML = 'Tips open at launch; nothing is charged until then. Tips never buy power, items or game time.';
    }
    function openSupportModal() {
      owJarLinks();
      var j = document.getElementById('owTipJar');
      if (j) j.classList.add('open');
    }
    function closeSupportModal() {
      var j = document.getElementById('owTipJar');
      if (j) j.classList.remove('open');
    }
    document.addEventListener('keydown', function(e) { if (e.key === 'Escape') closeSupportModal(); });
    // One gentle prompt: after 45 s on the page or most of the way down, at most once every 21 days.
    var OW_NUDGE_KEY = 'openvanilla_nudge_at';
    function owNudgeClose() {
      var n = document.getElementById('owNudge');
      if (n) n.classList.remove('show');
      var p = document.getElementById('owSupportPill');
      if (p) p.style.display = '';
      try { localStorage.setItem(OW_NUDGE_KEY, String(Date.now())); } catch (e) {}
    }
    (function owNudgeSetup() {
      var last = 0;
      try { last = Number(localStorage.getItem(OW_NUDGE_KEY) || 0); } catch (e) { return; }
      if (Date.now() - last < 21 * 864e5) return;
      var shown = false;
      function show() {
        if (shown || document.getElementById('owTipJar').classList.contains('open')) return;
        shown = true;
        var p = document.getElementById('owSupportPill');
        if (p) p.style.display = 'none';
        document.getElementById('owNudge').classList.add('show');
        try { localStorage.setItem(OW_NUDGE_KEY, String(Date.now())); } catch (e) {}
      }
      setTimeout(show, 45000);
      window.addEventListener('scroll', function() {
        var h = document.documentElement;
        if ((h.scrollTop + innerHeight) / h.scrollHeight > 0.6) show();
      }, { passive: true });
    })();
"""

OLD_JS = """    function openSupportModal() {
      showToast('Open Vanilla is free and non-commercial. In-game perks and donations are disabled.', 'bolt');
    }
    function closeSupportModal() {}
"""


def apply(path):
    s = open(path, encoding="utf-8").read()
    if MARK in s:
        print(f"{path}: already has the tip jar")
        return
    assert OLD_JS in s, "old openSupportModal not found"
    s = s.replace(OLD_JS, "", 1)
    i = s.index("</style>")
    s = s[:i] + CSS + "  " + s[i:]
    j = s.index("  <footer")
    s = s[:j] + HTML.lstrip("\n") + "\n" + s[j:]
    anchor = "    // Addons & Mod Repository"
    assert anchor in s, "script anchor not found"
    s = s.replace(anchor, JS.lstrip("\n") + "\n" + anchor, 1)
    links = "      COMMUNITY_FEED_URL: 'https://play.openvanilla.app/community/feed.json',"
    if links in s:
        s = s.replace(links, links + "\n      // Tip jar: a BTCPay store page and a Ko-fi / GitHub Sponsors page (https only).\n"
                      "      DONATE_CRYPTO_URL: '',\n      DONATE_CARD_URL: '',", 1)
    open(path, "w", encoding="utf-8", newline="").write(s)
    print(f"{path}: tip jar added")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        apply(p)
