"""Workshop Asset Validator: enforces licence allowlist, art budgets, and provenance.

Policy Matrix:
  - CC0-1.0, MIT, Apache-2.0: Accepted without restriction.
  - CC-BY-4.0, CC-BY-SA-4.0: Accepted (derived M2 retains BY-SA).
  - CC-BY-NC-4.0: Accepted with flag (kept out of core kits).
  - No-Derivatives (*-ND): REJECTED (glb-to-M2 conversion produces a derivative work).
  - Sketchfab / Fab Standard: REJECTED (standalone redistribution prohibited).
  - Quaternius: Allowed only baked inside built realm patches, NOT standalone workshop download.
  - Meshy / Tripo Free: Accepted with mandatory vendor attribution.
  - TRELLIS: Accepted with disclosure.
  - Hunyuan3D: REJECTED (regional exclusion clauses in licence).
"""
import json
import os
import sys

ALLOWED_LICENSES = {
    "CC0-1.0": {"status": "accept", "note": "Public domain"},
    "CC-BY-4.0": {"status": "accept", "note": "Attribution required in CREDITS"},
    "CC-BY-SA-4.0": {"status": "accept", "note": "ShareAlike applies to derived M2"},
    "CC-BY-NC-4.0": {"status": "flag", "note": "Non-commercial only; kept out of core kits"},
    "MIT": {"status": "accept", "note": "Permissive"},
    "Apache-2.0": {"status": "accept", "note": "Permissive with patent grant"},
    "Open-Vanilla-Asset-Pledge": {"status": "accept", "note": "Dedicated to Open Vanilla under CC0"},
}

BANNED_LICENSE_PATTERNS = [
    "-ND",
    "NO-DERIVATIVES",
    "SKETCHFAB",
    "FAB-STANDARD",
    "HUNYUAN",
]

# Approximate tri budgets by asset role for vanilla 1.12 engine compatibility
ROLE_TRIANGLE_BUDGETS = {
    "doodad": 1200,
    "building_kit": 3500,
    "creature": 2500,
    "mount": 3000,
    "item_weapon": 800,
    "item_armor": 600,
    "humanoid_npc": 2800,
}


def validate_workshop_sidecar(data: dict) -> tuple[bool, list[str]]:
    """Validate a workshop.json dictionary against Open Vanilla policy."""
    errors = []
    warnings = []

    # 1. Licence Validation
    lic = (data.get("license") or "").strip()
    if not lic:
        errors.append("Missing required 'license' field")
    else:
        lic_upper = lic.upper()
        for banned in BANNED_LICENSE_PATTERNS:
            if banned in lic_upper:
                errors.append(f"Licence '{lic}' is rejected by policy ({banned} not permitted)")

        if lic not in ALLOWED_LICENSES:
            if not any(b in lic_upper for b in BANNED_LICENSE_PATTERNS):
                errors.append(f"Licence '{lic}' is not in the approved allowlist")
        else:
            policy = ALLOWED_LICENSES[lic]
            if policy["status"] == "flag":
                warnings.append(f"Flagged licence '{lic}': {policy['note']}")

    # 2. AI Disclosure
    ai = data.get("ai_disclosure", {})
    if ai.get("used_ai"):
        tool = (ai.get("tool") or "").lower()
        if "hunyuan" in tool:
            errors.append("Hunyuan3D outputs are not permitted due to regional licence restrictions")
        if tool in ("meshy", "tripo") and not any("Meshy" in a or "Tripo" in a for a in data.get("authors", [])):
            warnings.append(f"Free-tier {tool.capitalize()} requires attribution to vendor in authors list")

    # 3. Quaternius check
    for author in data.get("authors", []):
        if "Quaternius" in author and data.get("role") != "built_patch_only":
            warnings.append("Quaternius assets may only be distributed inside built realm patches, not standalone")

    # 4. Budget check
    role = data.get("role")
    triangles = data.get("budgets", {}).get("triangle_count", 0)
    if role in ROLE_TRIANGLE_BUDGETS and triangles > 0:
        max_budget = ROLE_TRIANGLE_BUDGETS[role]
        if triangles > max_budget * 2:
            errors.append(f"Triangle count {triangles} exceeds maximum budget {max_budget * 2} for role '{role}'")
        elif triangles > max_budget:
            warnings.append(f"Triangle count {triangles} is high for role '{role}' (target {max_budget})")

    # 5. Required fields
    if not data.get("authors"):
        errors.append("At least one author must be credited")
    if not data.get("name"):
        errors.append("Asset name is required")

    return (len(errors) == 0, errors + warnings)
