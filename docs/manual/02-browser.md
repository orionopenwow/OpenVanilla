slug: browser
title: Playing in the browser
kicker: Chapter 2 · Play
summary: Play the full game in a browser tab: requirements, first load, textures, phones and tablets, guest play, and the page's tools.

## What you need {#requirements}

The browser client needs **WebGPU**. Current desktop Chrome and Edge have it; other browsers vary. If the page reports "no WebGPU adapter", update your browser or graphics driver, or use the launcher instead. A broadband connection helps for the first load.

## The first load and caching {#first-load}

The first visit downloads the game data the realm streams to you, and keeps it on your disk. The next visit loads from disk and only fetches what changed. The page asks your browser to keep this storage (Firefox shows a prompt; Chrome doesn't), so your keybinds, macros and addon settings survive too.

> **Note:** Browser settings are stored in that browser only. A different browser or device starts fresh.

## Textures: auto, lite, full {#textures}

Your first trip into the world uses **lite** textures (about a quarter of the texture data) so you're playing sooner. After two minutes in the world the page switches to full textures on your next load. The dock's **Textures** button cycles **auto / lite / full**; changes apply on the next load.

## The dock and page tools {#dock}

The handle at the top centre opens the dock: account, password, notifications (bell), full screen and sign out.

- **Full screen** captures Escape, Tab and W, so Ctrl+W won't close the tab by accident.
- **♫ Listening** (in the ☰ menu) shares what you're listening to on your Persona, if you want: see [the website chapter](website.html#now-playing).
- If the realm is full, slow or down, a note offers **Play Solo on your PC** instead.

## Phones and tablets {#touch}

Touch controls turn on by themselves on touch screens. Hold your phone **sideways**.

| Control | Where | Does |
| --- | --- | --- |
| Move stick | Bottom left, wherever you put your thumb | Move; double-tap toggles auto-run |
| Attack / Interact | Bottom right, large key | Attack or talk to your target |
| Target reticle | Next to Attack | Target; hold to clear |
| Ability arc | Four keys around Attack | Swipe or tap the dots for the next four |
| Jump | Under Attack | Jump |
| Tray | Top right | Bags, Quests, Chat, Menu |

Gestures: tap = click, double-tap = right-click, long-press = tooltip, drag = turn the camera, pinch = zoom. **Menu → Controls** switches between **Classic**, **Simple** and **Keyboard & mouse**. A connected gamepad takes over and hides the touch controls.

> **Note:** iPhone Safari can't go full screen; use **Share → Add to Home Screen** for a full-screen app icon.

## Guest play {#guest}

**Play as guest** creates a real account kept on that device (a cookie, for 400 days). Pressing it again on the same device brings back the same guest. Guests that sit unused for 30 days are removed. To keep your characters, press **⭐ Save your heroes — link Discord** in the game: same characters, now on your Discord-linked account.

## If something goes wrong {#trouble}

| Message | What to do |
| --- | --- |
| "Guest play is off on this realm" | Sign in with Discord instead |
| "No more guest accounts today" | The daily guest limit was reached; sign in with Discord |
| "Too many sign-ins" | Wait a few minutes and try again |
| Stuck on "Signing in" | Wait a few seconds: the login form comes back; sign in again |
| Black screen or "no WebGPU adapter" | Update the browser and graphics driver, or use the launcher |

Signing in on a phone and Discord came back in another browser? Both pages show the same 4-digit code: confirm on the page showing it, or choose **Play here instead**. More fixes in [Troubleshooting](troubleshooting.html).
