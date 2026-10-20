// The Open Vanilla Manual: sidebar search and "you are here" in the section list.
(() => {
  // On phones the chapter list starts folded (except on the contents page) so the page itself comes first.
  const box0 = document.querySelector('details.chapters-box');
  if (box0 && window.matchMedia('(max-width: 880px)').matches && !/\/(index\.html)?$/.test(location.pathname)) box0.open = false;
  const box = document.querySelector('.search');
  const res = document.querySelector('ol.results');
  let index = null;
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  async function load() {
    if (index) return index;
    try { index = await (await fetch('search.json')).json(); } catch { index = []; }
    return index;
  }
  box?.addEventListener('input', async () => {
    const q = box.value.trim().toLowerCase();
    if (q.length < 2) { res.hidden = true; return; }
    const words = q.split(/\s+/);
    const hits = (await load())
      .map((e) => {
        const t = e.t.toLowerCase(), x = e.x.toLowerCase();
        if (!words.every((w) => t.includes(w) || x.includes(w))) return null;
        return { e, score: words.reduce((s, w) => s + (t.includes(w) ? 3 : 1), 0) };
      })
      .filter(Boolean).sort((a, b) => b.score - a.score).slice(0, 12);
    res.innerHTML = hits.length
      ? hits.map(({ e }) => `<li><a href="${e.u}">${esc(e.t)}<small>${esc(e.c)}</small></a></li>`).join('')
      : '<li class="none">Nothing found. Try fewer words.</li>';
    res.hidden = false;
  });
  box?.addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter') { const a = res.querySelector('a'); if (a) location.href = a.href; }
    if (ev.key === 'Escape') { box.value = ''; res.hidden = true; }
  });
  document.addEventListener('keydown', (ev) => {
    if (ev.key === '/' && document.activeElement !== box) { ev.preventDefault(); box?.focus(); }
  });
  const links = [...document.querySelectorAll('nav.toc ol.secs a')];
  if (!links.length || !('IntersectionObserver' in window)) return;
  const byId = new Map(links.map((a) => [a.hash.slice(1), a]));
  const io = new IntersectionObserver((entries) => {
    for (const en of entries) {
      if (en.isIntersecting) {
        links.forEach((a) => a.classList.remove('here'));
        byId.get(en.target.id)?.classList.add('here');
      }
    }
  }, { rootMargin: '0px 0px -70% 0px' });
  document.querySelectorAll('section.ch').forEach((s) => io.observe(s));
})();
