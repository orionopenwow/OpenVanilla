# Activate your AI (optional)

Open Vanilla is open source, and your copy is yours to change. An AI coding agent can do the typing for
you: make an addon, restyle your interface, change your own realm's rates, add an NPC to your own
server, or get a realm running for your friends. You say what you want in plain words; it reads the
files, makes the change and tells you how to test and undo it.

This folder is the starter kit. The launcher copies it into your Open Vanilla data folder
(**Settings > AI > Set up AI workspace**), which becomes the agent's workspace:

```
CLAUDE.md          the guide Claude Code reads first: layout, rules, addons, servers
AGENTS.md          the same rules for other AI tools
Agent\README.md    this file
Agent\prompts\     ready-made prompts: copy one, paste it into your AI tool
```

## What you need

- An AI coding agent and **your own account** with its maker. Open Vanilla never asks for, stores or sends
  AI keys or logins, and has no partnership with any AI company.
- **Claude Code** works best with this kit (it reads `CLAUDE.md` by itself). Install it from
  <https://code.claude.com/docs/en/setup>; it needs a paid Claude plan (Pro, Max, Team or Enterprise)
  or an Anthropic Console account.
- Other agents that read and edit files (Codex CLI, Gemini CLI, Aider, Cursor, VS Code with an agent
  ...) work too: open this data folder in them and tell them to read `AGENTS.md` first.

## How to start

1. In the launcher: **Settings > AI**. If Claude Code isn't found, press **Install Claude Code** and
   follow its page, then restart the launcher.
2. Press **Set up AI workspace** (once; again after an update to refresh the kit. Files you edited are
   left alone).
3. Press **Open in Claude Code**. A terminal opens in your data folder running `claude`.
   (Other tools: press **Open workspace folder** and open it in your tool.)
4. Pick a prompt (launcher, in-game **Assistant** window, or `Agent\prompts\`), copy it, paste it in.

## Safety rules (the agent is told these too)

- It works on **your copy and your servers only**. The official Open Vanilla realm can't be changed from
  here, and your account there is not affected.
- It never touches Blizzard's game files or Open Vanilla's program files.
- It backs files up to `Backups\ai-<date>\` before changing them.
- Never paste passwords, tokens or keys into the AI. Type them yourself where they're needed.
- Read what it proposes before you say yes, especially commands that download or delete things.
- Something broke? Restore from `Backups\`, or switch the addon off in the launcher.
