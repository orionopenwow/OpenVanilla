#!/usr/bin/env python3
"""Who can see the staff channels? Finds and (with --fix) closes every way a non-staff member gets in.

  /opt/openvanilla-herald/venv/bin/python staff_audit.py          report only
  /opt/openvanilla-herald/venv/bin/python staff_audit.py --fix    close the leaks it found

Uses Herald's bot token and server id (/etc/openvanilla-herald.env: DISCORD_BOT_TOKEN, DISCORD_GUILD_ID).
Staff channels: everything in the 🔒 STAFF category, plus any channel named like one of them elsewhere
(alerts, gatehouse, gm-tickets, moderation, mod-log, support-queue, waves, staff-chat).

Checks, for each staff channel:
  * @everyone and every non-staff role: can it view the channel (its effective permission there)?
  * per-member overwrites that let a non-staff member in
Server-wide:
  * non-staff roles with Administrator (sees every channel whatever the overwrites), Manage Channels or
    Manage Roles (can let themselves in)
--fix sets each staff channel to: @everyone hidden, staff roles and Herald allowed, every other role and
member overwrite removed. Roles with Administrator are reported, never changed here: take it off by hand in
Server Settings > Roles if it shouldn't be there (the Founder decides).
"""
import asyncio, os, sys

STAFF_ROLES = {"Founder", "Admin", "Developer", "Game Master", "Moderator"}
STAFF_CATEGORY = "🔒 STAFF"
STAFF_NAMES = {"staff-chat", "alerts", "gatehouse", "waves", "gm-tickets", "moderation", "support-queue",
               "mod-log"}


def load_env(path="/etc/openvanilla-herald.env"):
    try:
        for line in open(path):
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.rstrip("\n").split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())
    except OSError:
        pass


async def main(fix):
    import discord
    load_env()
    token, gid = os.environ.get("DISCORD_BOT_TOKEN"), os.environ.get("DISCORD_GUILD_ID")
    if not token or not gid:
        sys.exit("DISCORD_BOT_TOKEN / DISCORD_GUILD_ID not set (/etc/openvanilla-herald.env)")
    intents = discord.Intents.default()
    intents.members = True
    client = discord.Client(intents=intents)
    problems = 0

    @client.event
    async def on_ready():
        nonlocal problems
        try:
            guild = client.get_guild(int(gid)) or await client.fetch_guild(int(gid))
            staff = [r for r in guild.roles if r.name in STAFF_ROLES]
            others = [r for r in guild.roles if r.name not in STAFF_ROLES and not r.managed]
            print(f"Server {guild.name}: staff roles {', '.join(r.name for r in staff) or 'NONE FOUND'}")
            for r in others:
                p = r.permissions
                risky = [n for n in ("administrator", "manage_channels", "manage_roles", "manage_guild") if getattr(p, n)]
                if risky:
                    problems += 1
                    holders = len(r.members)
                    print(f"  ! role @{r.name} ({holders} members) has {', '.join(risky)}: it can see or open every channel")
            chans = [c for c in guild.channels if not isinstance(c, discord.CategoryChannel)
                     and ((c.category and c.category.name == STAFF_CATEGORY) or any(n in c.name for n in STAFF_NAMES))]
            cat = discord.utils.get(guild.categories, name=STAFF_CATEGORY)
            targets = ([cat] if cat else []) + chans
            if not targets:
                print("  no staff channels found")
            for c in targets:
                leaks = []
                for r in others:
                    if c.permissions_for(r).view_channel:
                        leaks.append("@" + r.name)
                for target, ow in c.overwrites.items():
                    if isinstance(target, (discord.Member, discord.User)) and ow.view_channel and \
                            not any(r.name in STAFF_ROLES for r in getattr(target, "roles", [])) and target.id != client.user.id:
                        leaks.append(f"member {target}")
                name = f"{'category ' if isinstance(c, discord.CategoryChannel) else '#'}{c.name}"
                if leaks:
                    problems += 1
                    print(f"  ! {name}: visible to {', '.join(leaks)}")
                else:
                    print(f"  ok {name}: staff only")
                if fix and leaks:
                    over = {guild.default_role: discord.PermissionOverwrite(view_channel=False),
                            guild.me: discord.PermissionOverwrite(view_channel=True, send_messages=True,
                                                                  embed_links=True, read_message_history=True)}
                    for r in staff:
                        over[r] = discord.PermissionOverwrite(view_channel=True, send_messages=True,
                                                              read_message_history=True)
                    await c.edit(overwrites=over, reason="Staff channels: staff only (staff_audit.py)")
                    print(f"    fixed {name}")
            print("No leaks." if not problems else
                  f"{problems} problem(s)." + ("" if fix else " Run again with --fix to close the channel leaks."))
        finally:
            await client.close()

    await client.start(token)


if __name__ == "__main__":
    asyncio.run(main("--fix" in sys.argv))
