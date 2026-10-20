/*
 * Open Vanilla Workshop — shared code for workshop.html and workshop/{addon,creator,collection}.html.
 *
 * Static data: community/workshop/index.json and community/workshop/<id>.json (tools/workshop_build.py).
 * Live data: the realm's /api/workshop/* (wenilla-realm patch 0013): ratings, reviews, installs,
 * player collections, uploads. When the realm is unreachable the pages fall back to read-only and
 * show the snapshot numbers baked into the JSON.
 * Everything from the network is inserted as text (esc()), never as HTML.
 */
(function () {
  "use strict";
  var script = document.currentScript;
  // Pages in /workshop/ load this file as "workshop.js", workshop.html as "workshop/workshop.js".
  var ROOT = script && /(^|\/)workshop\/workshop\.js(\?|$)/.test(script.getAttribute("src") || "") ? "" : "../";
  var API = location.hostname === "play.openvanilla.app" ? "/api/workshop/" : "https://play.openvanilla.app/api/workshop/";
  var SITE = "https://openvanilla.app/";

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  // a URL that can't break out of url('...') in a style attribute (quotes and brackets encoded)
  function cssUrl(u) { return String(u).replace(/['"()\\\s]/g, function (c) { return "%" + c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0"); }); }
  function url(path) { return ROOT + path; }
  function page(name, q) { return (ROOT ? "" : "workshop/") + name + (q || ""); }
  function q(name) { return new URLSearchParams(location.search).get(name) || ""; }
  function safeHttp(u) { return /^https:\/\//.test(u || "") ? u : ""; }

  function getJSON(path) {
    return fetch(path, { cache: "no-cache", headers: { Accept: "application/json" } }).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    });
  }

  var indexP = null;
  function index() {
    if (!indexP) indexP = getJSON(url("community/workshop/index.json"));
    return indexP;
  }
  function addon(id) {
    if (!/^[a-z0-9][a-z0-9-]{1,47}$/.test(id)) return Promise.reject(new Error("bad id"));
    return getJSON(url("community/workshop/" + id + ".json"));
  }

  // ---- the realm API
  var online = null; // null = not tried, true/false after the first call
  function api(path, opts) {
    opts = opts || {};
    var init = { method: opts.method || "GET", credentials: "include", headers: { Accept: "application/json" }, cache: "no-store" };
    if (opts.csrf) init.headers["X-CSRF-Token"] = opts.csrf;
    if (opts.json !== undefined) { init.headers["Content-Type"] = "application/json"; init.body = JSON.stringify(opts.json); }
    if (opts.body !== undefined) { init.headers["Content-Type"] = opts.type || "application/octet-stream"; init.body = opts.body; }
    var ctrl = window.AbortController ? new AbortController() : null;
    if (ctrl) { init.signal = ctrl.signal; setTimeout(function () { ctrl.abort(); }, opts.timeout || 8000); }
    return fetch(API + path, init).then(function (r) {
      online = true;
      return r.text().then(function (t) {
        var body = null;
        try { body = t ? JSON.parse(t) : null; } catch (e) { body = { error: t }; }
        if (!r.ok) {
          var err = new Error((body && body.error) || ("HTTP " + r.status));
          err.status = r.status;
          throw err;
        }
        return body;
      });
    }, function (e) { online = false; e.status = 0; throw e; });
  }

  var meP = null;
  function me() {
    if (!meP) meP = api("me").catch(function (e) { return { signedOut: e.status === 401 || e.status === 403, offline: e.status === 0 }; });
    return meP;
  }
  var statsP = null;
  function stats() {
    if (!statsP) statsP = api("stats").then(function (s) { return s.addons || {}; }, function () { return null; });
    return statsP;
  }
  function mergeStats(cards, live) {
    if (!live) return cards;
    cards.forEach(function (c) {
      var s = live[c.id];
      c.stats = { rating: s ? s.rating : 0, votes: s ? s.votes : 0, installs: s ? s.installs : 0 };
    });
    return cards;
  }

  // ---- bits of HTML
  function stars(r, big) {
    var out = "", v = Math.round((Number(r) || 0) * 2) / 2;
    for (var i = 1; i <= 5; i++) {
      var f = v >= i ? "full" : (v >= i - 0.5 ? "half" : "empty");
      out += '<img src="' + url("assets/workshop/star_" + f + ".png") + '" alt="">';
    }
    return '<span class="stars' + (big ? " big" : "") + '" role="img" aria-label="' + (v ? v + " out of 5 stars" : "not rated yet") + '">' + out + "</span>";
  }
  var BADGES = {
    works: ["Works", "badge_works"], partly: ["Partly", "badge_partly"], "needs-fixes": ["Needs fixes", "badge_needs"],
    unknown: ["Not checked", "badge_unknown"], ours: ["Ours", "badge_ours"]
  };
  var TIPS = {
    works: "Loaded and logged in clean in the Vanilla simulator.",
    partly: "Loads; parts use client features the simulator does not model, or later-client code paths.",
    "needs-fixes": "Errors on load or at login in the Vanilla simulator.",
    unknown: "Not scanned (only addons we may host are scanned).",
    ours: "Made by Open Vanilla for Classic+; ships with the client."
  };
  function badge(kind) {
    var b = BADGES[kind] || BADGES.unknown;
    return '<span class="badge ' + esc(kind) + '" title="' + esc(TIPS[kind] || "") + '"><img src="' + url("assets/workshop/" + b[1] + ".webp") + '" alt="">' + b[0] + "</span>";
  }
  function badges(c) {
    return (c.ours ? badge("ours") : "") + badge(c.compat || "unknown");
  }
  function fmtNum(n) { n = Number(n) || 0; return n >= 10000 ? Math.round(n / 1000) + "k" : n >= 1000 ? (n / 1000).toFixed(1) + "k" : String(n); }
  function fmtSize(b) { b = Number(b) || 0; return b >= 1048576 ? (b / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(b / 1024)) + " KB"; }
  function fmtDate(t) {
    var d = typeof t === "number" ? new Date(t * 1000) : new Date(t);
    return isNaN(d) ? "" : d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
  }
  function card(c) {
    var thumb = url(c.thumb || ("assets/workshop/cat_" + (c.category || "utility") + ".webp"));
    var s = c.stats || {};
    return '<a class="card" href="' + page("addon.html", "?id=" + encodeURIComponent(c.id)) + '">' +
      '<div class="thumb" style="background-image:url(\'' + esc(cssUrl(thumb)) + '\')"><div class="badges">' + badges(c) + "</div></div>" +
      '<div class="body"><div class="name">' + esc(c.name) + '</div><div class="by">by ' + esc(c.author || "unknown") + "</div>" +
      '<div class="sum">' + esc(c.summary) + "</div>" +
      '<div class="meta"><span>' + stars(s.rating) + " " + (s.votes ? esc(s.votes) : "") + "</span>" +
      "<span>" + (s.installs ? esc(fmtNum(s.installs)) + " installs · " : "") +
      (c.install ? '<span class="chip hosted" title="Installs from the Workshop">Hosted</span>' : '<span class="chip" title="Download from the author">Link</span>') +
      "</span></div></div></a>";
  }
  function installHref(ids) { return "openvanilla://workshop/install/" + ids.map(encodeURIComponent).join(","); }
  function signInHref() { return "https://play.openvanilla.app/login"; }

  function setMeta(title, desc) {
    document.title = title + " · Open Vanilla Workshop";
    var m = document.querySelector('meta[name="description"]');
    if (m && desc) m.setAttribute("content", desc);
  }

  window.OWW = {
    ROOT: ROOT, API: API, SITE: SITE, esc: esc, url: url, page: page, q: q, safeHttp: safeHttp,
    index: index, addon: addon, api: api, me: me, stats: stats, mergeStats: mergeStats,
    stars: stars, badge: badge, badges: badges, card: card, fmtNum: fmtNum, fmtSize: fmtSize, fmtDate: fmtDate,
    installHref: installHref, signInHref: signInHref, setMeta: setMeta,
    isOnline: function () { return online; }
  };
})();
