"""Armory Embeds: server-rendered character cards, OpenGraph tags, and oEmbed responses.

Used by:
  - Forum signatures (SVG/PNG)
  - Discord and social link unfurls (OpenGraph)
  - oEmbed consumers (/api/oembed endpoint)
  - Creator and guild sites

Preserves privacy: only shows verified prestige milestones and respects character privacy.
"""
import html
import json
import xml.sax.saxutils as saxutils

CLASS_COLORS = {
    1: "#c79c6e",  # Warrior
    2: "#f58cba",  # Paladin
    3: "#abd473",  # Hunter
    4: "#fff569",  # Rogue
    5: "#ffffff",  # Priest
    7: "#0070de",  # Shaman
    8: "#69ccf0",  # Mage
    9: "#9482c9",  # Warlock
    11: "#ff7d0a", # Druid
}

RACE_NAMES = {
    1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf",
    5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"
}

CLASS_NAMES = {
    1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue",
    5: "Priest", 7: "Shaman", 8: "Mage", 9: "Warlock", 11: "Druid"
}


def render_card_svg(char: dict, realm_name: str, tier_name: str = "Verified", verified: bool = True) -> str:
    """Generate an SVG character card for forum signatures and web embeds."""
    name = saxutils.escape(char.get("name", "Unknown Hero"))
    level = char.get("level", 60)
    race_id = char.get("race_id", 1)
    class_id = char.get("class_id", 1)
    race = RACE_NAMES.get(race_id, "Adventurer")
    cls_name = CLASS_NAMES.get(class_id, "Hero")
    cls_color = CLASS_COLORS.get(class_id, "#f0c058")
    realm = saxutils.escape(realm_name)
    tier = saxutils.escape(tier_name)

    badge_bg = "rgba(94, 224, 138, 0.2)" if verified else "rgba(148, 163, 184, 0.2)"
    badge_border = "#5ee08a" if verified else "#94a3b8"
    badge_text = "#5ee08a" if verified else "#94a3b8"

    milestone = saxutils.escape(char.get("top_title") or f"Level {level} {cls_name}")

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="500" height="140" viewBox="0 0 500 140">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#0a0d16" />
      <stop offset="100%" stop-color="#05060a" />
    </linearGradient>
    <linearGradient id="gold" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#f0c058" />
      <stop offset="100%" stop-color="#c8932e" />
    </linearGradient>
  </defs>

  <!-- Background card -->
  <rect x="1" y="1" width="498" height="138" rx="8" fill="url(#bg)" stroke="#6d5426" stroke-width="1.5" />

  <!-- Accent bar -->
  <rect x="1" y="1" width="8" height="138" rx="4" fill="{cls_color}" />

  <!-- Character Name & Level -->
  <text x="26" y="38" font-family="'Segoe UI', Roboto, sans-serif" font-size="22" font-weight="bold" fill="#ffffff">{name}</text>
  <text x="26" y="62" font-family="'Segoe UI', Roboto, sans-serif" font-size="14" fill="{cls_color}">Level {level} {race} {cls_name}</text>

  <!-- Realm & Milestone -->
  <text x="26" y="92" font-family="'Segoe UI', Roboto, sans-serif" font-size="13" fill="#94a3b8">Realm: <tspan fill="#e2e8f0">{realm}</tspan></text>
  <text x="26" y="114" font-family="'Segoe UI', Roboto, sans-serif" font-size="12" fill="#ffd179">★ {milestone}</text>

  <!-- Verification Badge -->
  <rect x="360" y="20" width="120" height="26" rx="4" fill="{badge_bg}" stroke="{badge_border}" stroke-width="1" />
  <text x="420" y="37" font-family="'Segoe UI', Roboto, sans-serif" font-size="11" font-weight="bold" fill="{badge_text}" text-anchor="middle">✓ {tier.upper()}</text>

  <!-- Brand watermark -->
  <text x="480" y="122" font-family="Georgia, serif" font-size="11" fill="#6d5426" text-anchor="end">OPEN VANILLA</text>
</svg>"""
    return svg


def render_opengraph_html(char: dict, realm_name: str, card_img_url: str, canonical_url: str) -> str:
    """Generate HTML OpenGraph header tags for rich unfurls."""
    name = html.escape(char.get("name", "Character"))
    level = char.get("level", 60)
    cls_name = CLASS_NAMES.get(char.get("class_id", 1), "Hero")
    desc = f"Level {level} {cls_name} on {realm_name}. Verified character record on Open Vanilla."

    return f"""<!-- OpenGraph metadata -->
<meta property="og:type" content="profile">
<meta property="og:site_name" content="Open Vanilla Armory">
<meta property="og:title" content="{name} · {realm_name}">
<meta property="og:description" content="{desc}">
<meta property="og:url" content="{html.escape(canonical_url)}">
<meta property="og:image" content="{html.escape(card_img_url)}">
<meta property="og:image:width" content="500">
<meta property="og:image:height" content="140">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{name} · {realm_name}">
<meta name="twitter:description" content="{desc}">
<meta name="twitter:image" content="{html.escape(card_img_url)}">"""


def render_oembed_json(char: dict, realm_name: str, char_url: str, card_img_url: str, maxwidth: int = 600) -> dict:
    """Generate oEmbed JSON reply for embedding in external sites."""
    name = char.get("name", "Character")
    width = min(maxwidth, 500)
    height = int(width * (140 / 500))

    return {
        "version": "1.0",
        "type": "rich",
        "provider_name": "Open Vanilla Armory",
        "provider_url": "https://openvanilla.app",
        "title": f"{name} · {realm_name}",
        "author_name": name,
        "author_url": char_url,
        "width": width,
        "height": height,
        "html": f'<iframe src="{char_url}/card" width="{width}" height="{height}" frameborder="0" scrolling="no" style="border:0;overflow:hidden;border-radius:8px;"></iframe>',
        "thumbnail_url": card_img_url,
        "thumbnail_width": 500,
        "thumbnail_height": 140,
    }
