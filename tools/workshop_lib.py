"""Shared pieces of the Open Vanilla Workshop tools (workshop_index / _build / _scan / _port).

The Workshop lists vanilla 1.12 addons. It *hosts* only addons whose licence allows
redistribution (the allow-list below); every other addon is a link to its author's page.
"""
import os
import re

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_DIR = os.path.join(ROOT, "workshop", "catalog")
ADDONS_DIR = os.path.join(ROOT, "Data", "Interface", "AddOns")
OUT_DIR = os.path.join(ROOT, "www", "community", "workshop")

# SPDX ids we may rehost (redistribution allowed, with the licence and credit kept).
ALLOWED_LICENSES = {
    "MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "GPL-2.0", "GPL-3.0",
    "LGPL-2.1", "LGPL-3.0", "MPL-2.0", "Unlicense", "CC0-1.0",
}
# Spellings people put in .toc files / yml by hand -> SPDX.
LICENSE_ALIASES = {
    "mit": "MIT", "bsd": "BSD-3-Clause", "bsd-2": "BSD-2-Clause", "bsd-2-clause": "BSD-2-Clause",
    "bsd-3": "BSD-3-Clause", "bsd-3-clause": "BSD-3-Clause", "apache": "Apache-2.0",
    "apache-2.0": "Apache-2.0", "apache 2.0": "Apache-2.0", "gpl": "GPL-3.0", "gplv2": "GPL-2.0",
    "gpl-2.0": "GPL-2.0", "gpl-2.0-only": "GPL-2.0", "gpl-2.0-or-later": "GPL-2.0", "gpl2": "GPL-2.0",
    "gplv3": "GPL-3.0", "gpl-3.0": "GPL-3.0", "gpl-3.0-only": "GPL-3.0", "gpl-3.0-or-later": "GPL-3.0",
    "gpl3": "GPL-3.0", "lgpl": "LGPL-3.0", "lgpl-2.1": "LGPL-2.1", "lgpl-2.1-only": "LGPL-2.1",
    "lgpl-2.1-or-later": "LGPL-2.1", "lgpl-3.0": "LGPL-3.0", "lgpl-3.0-only": "LGPL-3.0",
    "lgpl-3.0-or-later": "LGPL-3.0", "mpl-2.0": "MPL-2.0", "mpl": "MPL-2.0", "unlicense": "Unlicense",
    "the unlicense": "Unlicense", "cc0": "CC0-1.0", "cc0-1.0": "CC0-1.0", "public domain": "CC0-1.0",
    "agpl-3.0": "AGPL-3.0", "all rights reserved": "Proprietary", "proprietary": "Proprietary",
}
COMPAT_VALUES = ("works", "partly", "needs-fixes", "unknown")
CATEGORIES = {
    "interface": "Interface",
    "unitframes": "Unit frames",
    "combat": "Combat",
    "raid": "Raid & healing",
    "quests": "Quests & leveling",
    "bags": "Bags & items",
    "maps": "Maps",
    "social": "Chat & social",
    "economy": "Auction & gold",
    "professions": "Professions",
    "macros": "Macros & actions",
    "tooltips": "Tooltips",
    "utility": "Utility",
    "classicplus": "Classic+",
}

ID_RE = re.compile(r"^(?!(con|prn|aux|nul|com[1-9]|lpt[1-9])$)[a-z0-9][a-z0-9-]{1,47}$")  # no Windows device names


def norm_license(value):
    """SPDX id for a licence string (None / '' -> 'NOASSERTION')."""
    if not value:
        return "NOASSERTION"
    v = str(value).strip()
    if v in ALLOWED_LICENSES or v in ("AGPL-3.0", "Proprietary", "NOASSERTION", "Custom"):
        return v
    return LICENSE_ALIASES.get(v.lower(), v)


def may_rehost(license_id):
    return norm_license(license_id) in ALLOWED_LICENSES


def slug(text):
    s = re.sub(r"[^a-z0-9]+", "-", str(text).lower()).strip("-")
    return s[:48] or "addon"


def classify_license_text(text):
    """SPDX id from the text of a LICENSE/COPYING file; 'NOASSERTION' when unrecognised."""
    if not text:
        return "NOASSERTION"
    t = re.sub(r"\s+", " ", text).lower()
    if "gnu lesser general public license" in t or "gnu library general public license" in t:
        return "LGPL-2.1" if "version 2.1" in t else "LGPL-3.0"
    if "gnu affero general public license" in t:
        return "AGPL-3.0"
    if "gnu general public license" in t:
        if "version 3" in t:
            return "GPL-3.0"
        if "version 2" in t:
            return "GPL-2.0"
        return "GPL-3.0"
    if "apache license" in t and "version 2.0" in t:
        return "Apache-2.0"
    if "mozilla public license" in t and "2.0" in t:
        return "MPL-2.0"
    if "this is free and unencumbered software released into the public domain" in t:
        return "Unlicense"
    if "cc0 1.0 universal" in t or "creative commons zero" in t:
        return "CC0-1.0"
    if "permission is hereby granted, free of charge" in t:
        return "MIT"
    if "redistribution and use in source and binary forms" in t:
        return "BSD-3-Clause" if ("neither the name" in t or "may be used to endorse" in t) else "BSD-2-Clause"
    if "creative commons" in t and "noncommercial" in t:
        return "CC-BY-NC"
    if "all rights reserved" in t:
        return "Proprietary"
    return "NOASSERTION"


def read_toc(path):
    """{'meta': {key: value}, 'files': [...]} of a .toc; None when unreadable."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    meta, files = {}, []
    for line in lines:
        m = re.match(r"^##\s*([^:]+):\s*(.*?)\s*$", line)
        if m:
            meta[m.group(1).strip()] = m.group(2)
        elif line.strip() and not line.startswith("#"):
            files.append(line.strip())
    return {"meta": meta, "files": files}


def strip_codes(s):
    return re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", s or "").strip()


def load_catalog(catalog_dir=CATALOG_DIR):
    out = []
    if not os.path.isdir(catalog_dir):
        return out
    for name in sorted(os.listdir(catalog_dir)):
        if name.endswith(".yml"):
            with open(os.path.join(catalog_dir, name), encoding="utf-8") as f:
                data = yaml.safe_load(f) or {}
            data.setdefault("id", name[:-4])
            out.append(data)
    return out


FIELD_ORDER = ("id", "name", "author", "summary", "description", "category", "license", "rehost",
               "source_url", "homepage", "version", "added", "files", "screenshots", "tags", "compat",
               "ours", "folders", "verified", "upstream", "scan")


def dump_entry(entry):
    ordered = {k: entry[k] for k in FIELD_ORDER if k in entry}
    for k, v in entry.items():
        if k not in ordered:
            ordered[k] = v
    return yaml.safe_dump(ordered, sort_keys=False, allow_unicode=True, width=100)


def write_entry(entry, catalog_dir=CATALOG_DIR):
    os.makedirs(catalog_dir, exist_ok=True)
    path = os.path.join(catalog_dir, entry["id"] + ".yml")
    with open(path, "w", encoding="utf-8") as f:
        f.write(dump_entry(entry))
    return path
