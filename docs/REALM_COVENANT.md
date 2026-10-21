# The Open Vanilla Realm Covenant & Continuity Pledge

The Open Vanilla Realm Covenant is the foundational agreement between realm hosts,
players, and the Open Vanilla network. Inspired by the Mastodon Server Covenant,
it ensures that thousands of independent realms can flourish without centralized
abuse, commercial exploitation, or catastrophic data loss.

---

## 1. The Core Covenant Rules

Every realm listed in the Open Vanilla Directory commits to the following non-negotiable rules:

1. **Non-Commercial Operation (Nothing Sold)**
   - No microtransactions, cash shops, subscriptions, pay-to-win mechanics, or paid cosmetic items.
   - No perks, priority queues, in-game gold, or titles sold in exchange for donations.
   - Voluntary donations may only cover verified server hosting costs with transparent accounting.

2. **Bring Your Own Game Data (Zero Blizzard Assets Distributed)**
   - Realms and hosts never distribute or host Blizzard copyright-protected client files, MPQs, or proprietary assets.
   - Every player brings their own client data.
   - Realm builds and .ovpack files contain only original or community-created assets under permissive open licences (MIT, Apache-2.0, CC0, CC BY, CC BY-SA).

3. **No Blizzard Trademarks in Names or Public Displays**
   - Realm names, MOTDs, and directory listings must not claim official affiliation or use protected marks.

4. **Transparent Bot Policy (Bots Labelled and Counted Apart)**
   - Playerbots and AI companions are permitted, but **must always be clearly labelled** (e.g. `RNDBOT_` prefix or inspect badge).
   - In heartbeats and directory listings, bot counts must be strictly separated from human players authenticated by Hero Keys.
   - Artificial population inflation is grounds for immediate delisting.

5. **Continuity Pledge & Closure Notice (30–90 Days)**
   - Hosts agree to give players **at least 30 to 90 days of advance notice** before shutting down a realm.
   - Character Passport export must remain enabled so players can withdraw their signed character records.
   - On closure, custom packs, configs, and scripts must be published under an open licence (following the Ryzom precedent) to preserve community work.

6. **Daily Backups & Emergency Second Administrator**
   - Automated daily backups must be kept.
   - Every realm must designate at least one trusted successor or co-administrator with emergency access credentials.

7. **Active Moderation Against Hate and Harassment**
   - Maintain a posted Code of Conduct and clear contact information for administration.
   - Actively moderate against harassment, doxxing, and hate speech.

---

## 2. The Realm Will & Continuity Escrow

The fatal flaw of past private servers was the single point of failure: when an operator vanished, was attacked, or faced legal letters, player accounts and character history were destroyed or trapped.

The Open Vanilla Realm Will provides continuity before any crisis occurs:

1. **Successor Designation**: The host designates 1 or 2 successors identified by their Hero ID (`ovh1...`).
2. **Multi-Party Backup Escrow**: Encrypted database snapshots are periodically pushed to distributed escrow nodes (never a single central vault).
3. **Dormancy Trigger**: If directory heartbeats cease for 14 consecutive days, the realm is marked **Dormant**. Players receive automated notifications with one-click export links.
4. **Pass the Torch**: The successor can claim the escrowed snapshot using their successor key, reload the exact pinned `realm.json` recipe, and resume realm operations under a new host without data loss.
5. **Player-Held Passport Backstop**: Even if a realm disappears overnight with no successor, each player's locally held, Ed25519-signed `passport.json` preserves their character sheet and prestige milestones forever.

---

## 3. Trust Tiers and Enforcement

| Tier | Status | Verification Requirements | Capabilities |
|---|---|---|---|
| **Tier 0: Official** | Open Vanilla Team | Maintained by Open Vanilla core team | Full character import; cross-realm boards |
| **Tier 1: Verified** | Vetted Community | Reproducible build hash, signed recipe, Covenant signed, bots flagged, audit sampling accepted | Full character import (with stat caps); cross-realm boards |
| **Tier 2: Community** | Self-Hosted Listed | Heartbeats passing probe, valid host key, Covenant accepted | Cosmetic import (titles, appearances); per-realm boards |
| **Tier 3: Unverified** | Untrusted / Pocket | Unknown keys, unlisted hosts, browser sandbox | Legacy display inspect badge only |

### Graduated Enforcement:
Violations of the Covenant trigger proportionate, transparent enforcement:
1. **Notice & Warning**: 7-day cure period for technical or disclosure issues.
2. **Unverified Demotion**: Realm trust tier drops to Tier 3; full import is disabled.
3. **Hidden from Default Sort**: Realm is unranked and accessible only via direct search or direct link.
4. **Delisting**: Realm key removed from directory trust list.

*Delisting is directory-only. Open Vanilla never operates client-side blacklists or network chokepoints.*
