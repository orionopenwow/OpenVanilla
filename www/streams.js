/* Open Vanilla streams & creators: shared by streamers.html and creators.html.
 *
 * Data: community/streams.json, written every 5 minutes by tools/streams_fetch.py on the realm
 * server and served by its Caddy at https://play.openvanilla.app/community/ (CORS open). ?mock=1 reads
 * the canned community/streams.mock.json from this site instead; ?src=<url> any other copy.
 *
 * Players are the platforms' own official embeds (Twitch embed, YouTube iframe on
 * youtube-nocookie.com, TikTok's embed player, Kick's player) and load only when a visitor clicks:
 * until then nothing from those sites runs on the page apart from the thumbnail image.
 */
(function () {
  "use strict";
  var REMOTE = "https://play.openvanilla.app/community/streams.json";
  var LOCAL = "community/streams.json";
  var PLATFORMS = { twitch: "Twitch", youtube: "YouTube", tiktok: "TikTok", kick: "Kick" };

  function params() { return new URLSearchParams(location.search); }

  function load() {
    var p = params();
    // ?src= (another feed) is for local testing only: on the live site it would let anyone put their
    // own titles and links on the official streams page
    var local = /^(localhost|127\.0\.0\.1|\[::1\])$/.test(location.hostname);
    var src = p.get("mock") === "1" ? "community/streams.mock.json" : ((local && p.get("src")) || REMOTE);
    function get(url) {
      return fetch(url, { cache: "no-cache", headers: { Accept: "application/json" } }).then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      });
    }
    return get(src).catch(function (e) {
      if (src === LOCAL) throw e;
      return get(LOCAL);          // the repo's copy (empty until the server writes one)
    }).then(normalize);
  }

  function normalize(d) {
    d = d && typeof d === "object" ? d : {};
    ["live", "scheduled", "videos", "creators", "ingame"].forEach(function (k) { if (!Array.isArray(d[k])) d[k] = []; });
    if (!d.leaderboard || !Array.isArray(d.leaderboard.rows)) d.leaderboard = { month: "", rows: [] };
    return d;
  }

  function el(tag, attrs, kids) {
    var n = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach(function (k) {
      var v = attrs[k];
      if (v == null || v === false) return;
      if (k === "text") n.textContent = v;
      else if (k === "class") n.className = v;
      else if (k.slice(0, 2) === "on") n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v === true ? "" : v);
    });
    (kids || []).forEach(function (c) { if (c != null) n.append(c); });
    return n;
  }

  // Only https URLs on the platforms' own hosts are used as links and images.
  var HOSTS = /^https:\/\/([a-z0-9-]+\.)*(twitch\.tv|jtvnw\.net|youtube\.com|youtu\.be|ytimg\.com|yt3\.googleusercontent\.com|tiktok\.com|tiktokcdn\.com|tiktokcdn-us\.com|ibyteimg\.com|kick\.com|kick\.cloud)(\/|$)/i;
  function safeUrl(u) { return typeof u === "string" && HOSTS.test(u) ? u : ""; }

  function ago(iso) {
    var s = (Date.now() - Date.parse(iso)) / 1000;
    if (!isFinite(s)) return "";
    if (s < 0) return "";
    if (s < 3600) return Math.max(1, Math.floor(s / 60)) + "m";
    if (s < 86400) return Math.floor(s / 3600) + "h";
    return Math.floor(s / 86400) + "d";
  }
  function when(iso) {
    var t = Date.parse(iso);
    if (!isFinite(t)) return "";
    return new Date(t).toLocaleString(undefined, { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
  }
  function num(n) { n = Number(n) || 0; return n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k" : String(n); }
  function dur(s) { s = Number(s) || 0; if (!s) return ""; var m = Math.floor(s / 60); return m + ":" + String(s % 60).padStart(2, "0"); }

  /* The official embed for a stream or video, as an iframe src. */
  function embedSrc(e) {
    if (!e || typeof e !== "object") return "";
    var host = location.hostname || "openvanilla.app";
    var id = String(e.id || "").replace(/[^A-Za-z0-9_-]/g, "");
    var ch = String(e.channel || "").replace(/[^A-Za-z0-9_]/g, "");
    switch (e.type) {
      case "twitch": return ch ? "https://player.twitch.tv/?channel=" + ch + "&parent=" + encodeURIComponent(host) + "&autoplay=true&muted=true" : "";
      case "youtube": return id ? "https://www.youtube-nocookie.com/embed/" + id + "?autoplay=1&mute=1&rel=0" : "";
      case "tiktok": return id ? "https://www.tiktok.com/player/v1/" + id + "?autoplay=1&music_info=1&description=1" : "";
      case "kick": return ch ? "https://player.kick.com/" + ch + "?autoplay=true&muted=true" : "";
    }
    return "";
  }

  /* A card: thumbnail that becomes the player on click; the title links out to the platform. */
  function card(item, opts) {
    opts = opts || {};
    var p = PLATFORMS[item.platform] ? item.platform : "twitch";
    var thumb = safeUrl(item.thumbnail);
    var url = safeUrl(item.url);
    var media = el("button", { type: "button", class: "sc-media" + (item.kind === "short" ? " short" : ""), "aria-label": "Play " + (item.title || "") + " here" });
    if (thumb) media.append(el("img", { class: "sc-th", src: thumb, alt: "", loading: "lazy", referrerpolicy: "no-referrer", decoding: "async", onerror: function () { this.remove(); } }));
    media.append(el("img", { class: "sc-plat", src: "assets/streams/platform_" + p + ".png", alt: PLATFORMS[p], width: "28", height: "28" }));
    if (opts.live) media.append(el("span", { class: "sc-live", text: "LIVE" }));
    if (opts.live && item.viewers) media.append(el("span", { class: "sc-viewers", text: num(item.viewers) + " watching" }));
    if (!opts.live && item.duration) media.append(el("span", { class: "sc-viewers", text: dur(item.duration) }));
    media.append(el("span", { class: "sc-playglyph", "aria-hidden": "true", text: "▶" }));
    var src = embedSrc(item.embed);
    media.addEventListener("click", function () {
      if (!src) { if (url) window.open(url, "_blank", "noopener"); return; }
      var f = el("iframe", { src: src, title: item.title || PLATFORMS[p], allow: "autoplay; encrypted-media; picture-in-picture; fullscreen", allowfullscreen: true, referrerpolicy: "strict-origin-when-cross-origin", loading: "lazy" });
      var box = el("div", { class: "sc-media playing" + (item.kind === "short" ? " short" : "") }, [f]);
      media.replaceWith(box);
    });
    var meta = [item.creator || item.channel || ""];
    if (opts.live && item.started) meta.push("live for " + ago(item.started));
    if (opts.scheduled && item.scheduled) meta.push(when(item.scheduled));
    if (!opts.live && !opts.scheduled && item.published) meta.push(ago(item.published) + " ago");
    var title = url ? el("a", { href: url, target: "_blank", rel: "noopener noreferrer", text: item.title || "(untitled)" })
      : el("span", { text: item.title || "(untitled)" });
    var tags = el("div", { class: "sc-tags" });
    (item.classes || []).slice(0, 2).forEach(function (c) { tags.append(el("span", { class: "chip cls-" + c, text: c })); });
    (item.topics || []).slice(0, 3).forEach(function (t) { tags.append(el("span", { class: "chip", text: t })); });
    return el("article", { class: "sc-card", "data-platform": p }, [
      media,
      el("div", { class: "sc-body" }, [el("h3", { class: "sc-title" }, [title]), el("div", { class: "sc-meta", text: meta.filter(Boolean).join(" · ") }), tags.childNodes.length ? tags : null]),
    ]);
  }

  function empty(title, text) {
    return el("div", { class: "empty" }, [el("b", { text: title }), el("span", { text: text })]);
  }

  /* Per-platform tabs over a list: renders `items` into `grid` with the chosen platform only. */
  function tabs(bar, onPick) {
    var cur = "all";
    var buttons = [["all", "All"]].concat(Object.keys(PLATFORMS).map(function (k) { return [k, PLATFORMS[k]]; }));
    bar.setAttribute("role", "tablist");
    buttons.forEach(function (b) {
      var t = el("button", { type: "button", role: "tab", class: "tab", "data-k": b[0], "aria-selected": b[0] === cur ? "true" : "false" }, [
        b[0] === "all" ? null : el("img", { src: "assets/streams/platform_" + b[0] + ".png", alt: "", width: "18", height: "18" }), el("span", { text: b[1] }), el("small", { class: "n" })]);
      t.addEventListener("click", function () {
        cur = b[0];
        bar.querySelectorAll(".tab").forEach(function (x) { x.setAttribute("aria-selected", x === t ? "true" : "false"); });
        onPick(cur);
      });
      bar.append(t);
    });
    return {
      counts: function (c) { bar.querySelectorAll(".tab").forEach(function (x) { var n = c[x.getAttribute("data-k")] || 0; x.querySelector(".n").textContent = n ? String(n) : ""; }); },
      current: function () { return cur; },
    };
  }

  function updated(d) {
    var t = Date.parse(d.updated);
    if (!isFinite(t)) return "Waiting for the first update from the realm server.";
    var stale = Date.now() - t > 30 * 60 * 1000;
    return (stale ? "Last update " : "Updated ") + ago(d.updated) + " ago" + (stale ? " (the fetcher may be paused)" : "") + ".";
  }

  window.OWStreams = { load: load, el: el, card: card, empty: empty, tabs: tabs, updated: updated, safeUrl: safeUrl, PLATFORMS: PLATFORMS, ago: ago, when: when };
})();
