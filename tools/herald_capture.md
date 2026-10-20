# Recording a real clip of Herald (optional, later)

`www/herald.html` shows no animation. If a real in-game clip is wanted later, this note says how
to record one. Nothing here is implemented yet: owbot has no drive or record mode today.

## What exists today

- `tools/owbot.mjs` signs in to a realm with headless Chromium (Playwright), enters the world as
  Herald and runs the owdiag checks. `--shots` saves a PNG of each screen it passes into
  `owbot-shots/`. `--patrol N` walks around for N minutes. WebGPU runs on SwiftShader (the CPU), so
  the world renders at a few frames per second.
- `devkit/heraldlite` (`heraldlite autopilot`) plays the quest route over the game protocol, with no
  browser and so no picture.
- One account can be in the world once. The autopilot and a browser can't both be Herald at the same
  time.

## Two ways to get a picture

1. **Drive mode (preferred).** When owbot can play the route itself in the browser (planned
   `--drive`), record that session. The clip then shows Herald's own screen.
2. **Camera character.** Run `heraldlite autopilot` as Herald, and sign owbot in on a second bot
   account (a camera character parked by the Northshire boars or kobolds) that just watches. Use the
   staging realm, so no other players' names show up.

## Recording

Use Playwright's video recording (a WebM of the page) rather than one screenshot per frame:

```js
const context = await browser.newContext({
  viewport: { width: 1280, height: 600 },
  recordVideo: { dir: 'owbot-video', size: { width: 1280, height: 600 } },
});
const page = await context.newPage();
// ... sign in, play or watch the pull ...
await context.close();          // the .webm is written when the context closes
```

On SwiftShader the video is choppy. For a smooth clip, either run the capture on a machine with a
GPU (drop the `--use-webgpu-adapter=swiftshader` flag), or take screenshots as fast as the page
renders (`page.screenshot()` in a loop into `owbot-frames/f_0001.png ...`) and play them back at
15 fps as a time-lapse. If you do that, say so in the caption.

## Making the GIF

Keep the same file name and a size close to 640x300, under 3 MB, a 6 to 10 s loop:

```sh
# from a WebM: pick the 8 seconds of the pull with -ss / -t
ffmpeg -ss 12 -t 8 -i owbot-video/run.webm -vf \
  "fps=15,scale=640:-1:flags=lanczos,crop=640:300,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 www/assets/herald/herald_playing.gif

# from numbered screenshots
ffmpeg -framerate 15 -i owbot-frames/f_%04d.png -vf "scale=640:-1:flags=lanczos,crop=640:300,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 www/assets/herald/herald_playing.gif

# the still for people who prefer reduced motion (pick a good moment)
ffmpeg -ss 15 -i owbot-video/run.webm -frames:v 1 -vf "scale=640:-1:flags=lanczos,crop=640:300" \
  www/assets/herald/herald_playing.webp
```

Too big? Lower `fps` to 12, `max_colors` to 128, or shorten the clip. Check with
`ls -l www/assets/herald/herald_playing.gif`.

## Then

1. In `www/herald.html`, change the figure caption from "An illustration of one pull, not a
   recording..." to say where and when it was recorded (for example "Recorded on the staging realm,
   2026-11-02") and update the `alt` text to describe what the clip shows. If the size changed,
   update the `width`/`height` attributes.
2. Leave out other players' names and chat: record on staging, or crop them out.
3. Keep `tools/gen_herald_art.py` as it is. Running it again rewrites the illustration, so when
   you regenerate the other art, use `--stills-only`.
