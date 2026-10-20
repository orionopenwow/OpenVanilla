# Fix an addon error

Paste the error from the game's error dialog and let the agent find and fix it.

Works on: Your copy (your own or copied addons).

## Prompt

```text
Read CLAUDE.md. An addon shows a Lua error in game. Here is the error text: <paste the error here>. Find which addon and line it comes from, check Logs\ for anything related, explain the cause in plain words, back the file up, and fix it following the Lua 5.0 rules. If it is one of the shipped Open Vanilla addons, don't edit it in place: tell me, and suggest a report or a separate fix addon instead.
```

## Tips

- Replace <paste the error here> with the text of the error. Leave out anything that looks like a password.
