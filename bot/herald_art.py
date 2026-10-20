"""Live art: while Herald is online, a changed image in bot/discord_assets replaces the one in Discord.

The bot's own posts are edited in place (same message, same pins, same buttons), so nobody is pinged and
nothing moves:
  discord_assets/NN_name.png          the #welcome post that carries that image
  discord_assets/banners/banner_K.png the pinned info post in channel K (or forum K's "Read me" post)

Where the new images come from:
  - the folder itself (Herald running on your PC: save a new PNG over the old one, it's live in ~20 s)
  - ART_URL (Herald on the server): a base URL holding discord_assets/manifest.json, e.g.
    https://raw.githubusercontent.com/<you>/openvanilla/stable/bot/ . Herald checks it every ART_POLL_SEC
    (300) and downloads what changed, so pushing a new image is enough.
    Make the manifest with:  py -3 bot/herald_art.py --manifest

Staff commands: /art refresh [file]  (force one image, or every image)   /art status
Settings: ART_ENABLED=1 (default), ART_DIR (default bot/discord_assets), ART_URL, ART_POLL_SEC.
"""
import asyncio
import hashlib
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MARK = "Open Vanilla · "  # discord_content.py's footer prefix on the pinned info posts
OLD_MARKS = ("Open Vanilla · ",)  # before the rename


def env(name, default=None):
    v = os.environ.get(name)
    return v if v not in (None, "") else default


def enabled():
    return env("ART_ENABLED", "1") != "0"


def art_dir():
    return env("ART_DIR", os.path.join(HERE, "discord_assets"))


def scan(root):
    """relative path ('03_join.png', 'banners/banner_faq.png') -> sha256 of the file."""
    out = {}
    for sub in ("", "banners"):
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        for n in sorted(os.listdir(d)):
            if n.lower().endswith((".png", ".jpg", ".jpeg", ".webp", ".gif")):
                with open(os.path.join(d, n), "rb") as f:
                    out[(sub + "/" + n) if sub else n] = hashlib.sha256(f.read()).hexdigest()
    return out


def write_manifest(root=None):
    root = root or art_dir()
    m = scan(root)
    with open(os.path.join(root, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump({"files": m}, f, indent=1, sort_keys=True)
    print(f"{os.path.join(root, 'manifest.json')}: {len(m)} images")


def fetch_remote(base, root, have):
    """Download every image whose hash differs from the manifest at ``base``. Returns what changed."""
    base = base.rstrip("/") + "/discord_assets/"
    req = urllib.request.Request(base + "manifest.json", headers={"User-Agent": "OpenVanilla-Herald"})
    with urllib.request.urlopen(req, timeout=20) as r:  # nosec B310 - the project's own repo
        want = json.loads(r.read().decode("utf-8")).get("files", {})
    changed = []
    for rel, digest in want.items():
        if have.get(rel) == digest or ".." in rel or rel.startswith("/"):
            continue
        req = urllib.request.Request(base + rel, headers={"User-Agent": "OpenVanilla-Herald"})
        with urllib.request.urlopen(req, timeout=60) as r:  # nosec B310
            data = r.read()
        if hashlib.sha256(data).hexdigest() != digest:
            continue  # caught mid-push; next round
        path = os.path.join(root, *rel.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".part"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
        changed.append(rel)
    return changed


def install(bot, discord, chan, is_staff, gid):
    root = art_dir()
    state = {"hashes": scan(root), "last": None, "done": []}
    url = env("ART_URL")
    every = max(60, int(env("ART_POLL_SEC", "300")))

    def key_of(rel):
        name = rel.split("/")[-1]
        if rel.startswith("banners/") and name.startswith("banner_"):
            return "banner", name[len("banner_"):].rsplit(".", 1)[0]
        return "welcome", name

    async def replace(rel):
        """Swap the image in the bot's post that carries ``rel``. True when a post was updated."""
        guild = bot.get_guild(int(gid))
        if not guild:
            return False
        path = os.path.join(root, *rel.split("/"))
        if not os.path.isfile(path):
            return False
        kind, key = key_of(rel)
        me = guild.me
        if kind == "welcome":
            ch = chan(guild, "welcome")
            if not ch:
                return False
            async for m in ch.history(limit=50):
                if m.author.id == me.id and any(a.filename == key for a in m.attachments):
                    await m.edit(attachments=[discord.File(path, filename=key)])
                    return True
            return False
        fname = rel.split("/")[-1]
        target = chan(guild, key) or next((f for f in guild.forums if f.name == key), None)
        if target is None:
            return False
        if isinstance(target, discord.ForumChannel):
            threads = list(target.threads)
            try:
                threads += [t async for t in target.archived_threads(limit=50)]
            except discord.HTTPException:
                pass
            for t in threads:
                if t.owner_id == me.id and t.name.startswith("📌 Read me"):
                    msg = await t.fetch_message(t.id)
                    return await _swap(msg, path, fname)
            return False
        p = target.pins()
        pins = [m async for m in p] if hasattr(p, "__aiter__") else await p
        for m in pins:
            if m.author.id == me.id and m.embeds and (m.embeds[0].footer.text or "").startswith((MARK,) + OLD_MARKS):
                return await _swap(m, path, fname)
        return False

    async def _swap(msg, path, fname):
        e = msg.embeds[0] if msg.embeds else None
        if e is not None:
            e.set_image(url=f"attachment://{fname}")  # the old CDN link dies with the old attachment
            await msg.edit(embed=e, attachments=[discord.File(path, filename=fname)])
        else:
            await msg.edit(attachments=[discord.File(path, filename=fname)])
        return True

    async def apply(changed, why):
        results = []
        for rel in changed:
            try:
                ok = await replace(rel)
            except discord.HTTPException as e:
                print(f"[art] {rel}: Discord refused the edit ({e})")
                results.append(False)
                continue
            results.append(ok)
            print(f"[art] {rel}: {'updated in Discord' if ok else 'no post carries it yet (run discord_content.py)'} ({why})")
            state["done"].insert(0, (time.strftime("%H:%M"), rel, ok))
            del state["done"][20:]
        return results

    async def loop():
        await bot.wait_until_ready()
        next_remote = 0.0
        while not bot.is_closed():
            try:
                if url and time.time() >= next_remote:
                    next_remote = time.time() + every
                    got = await asyncio.to_thread(fetch_remote, url, root, state["hashes"])
                    if got:
                        print(f"[art] downloaded {len(got)} new image(s) from ART_URL")
                now = await asyncio.to_thread(scan, root)
                # first fill of an empty folder (a fresh server): that's the baseline, not a change
                changed = [r for r, h in now.items() if state["hashes"].get(r) != h] if state["hashes"] else []
                state["hashes"] = now
                state["last"] = time.strftime("%H:%M:%S")
                if changed:
                    await asyncio.sleep(2)  # let an editor finish writing the file
                    await apply(changed, "new file")
            except Exception as e:  # noqa: BLE001 - keep watching
                print(f"[art] {type(e).__name__}: {e}")
            await asyncio.sleep(20)

    grp = discord.app_commands.Group(name="art", description="Staff: the Discord images")

    @grp.command(name="refresh", description="Put the current image(s) into Discord now")
    async def refresh(inter: discord.Interaction, file: str = ""):
        if not is_staff(inter.user):
            return await inter.response.send_message("Staff only.", ephemeral=True)
        await inter.response.defer(ephemeral=True, thinking=True)
        files = [f for f in scan(root) if not file or f.endswith(file)]
        if not files:
            return await inter.followup.send(f"No image matches `{file}`.", ephemeral=True)
        results = await apply(files, f"/art refresh by {inter.user.display_name}")
        await inter.followup.send(f"Updated {sum(results)} of {len(files)} image(s) in Discord. Images no post "
                                  "carries yet need discord_content.py first.", ephemeral=True)

    @grp.command(name="status", description="What the live art watcher is doing")
    async def status(inter: discord.Interaction):
        if not is_staff(inter.user):
            return await inter.response.send_message("Staff only.", ephemeral=True)
        lines = [f"Watching `{root}` ({len(state['hashes'])} images), last check {state['last'] or 'not yet'}."]
        lines.append(f"Remote: {url} every {every // 60} min." if url else "Remote: off (set ART_URL on the server).")
        lines += [f"{t} {'✅' if k else '•'} {r}" for t, r, k in state["done"][:10]]
        await inter.response.send_message("\n".join(lines), ephemeral=True)

    bot.tree.add_command(grp)

    class Art:
        def start(self):
            self.task = asyncio.get_event_loop().create_task(loop())

    print(f"[art] live art on: watching {root}" + (f" and {url}" if url else ""))
    return Art()


if __name__ == "__main__":
    if "--manifest" in sys.argv:
        write_manifest()
    else:
        print(__doc__)
