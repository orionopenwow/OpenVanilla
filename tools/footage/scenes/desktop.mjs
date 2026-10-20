// Desktop apps, filmed by window title with ffmpeg (Windows). Nothing is clicked for you here: the
// app opens, gets a few seconds to settle, and its window is filmed. Tabs you want in the shot can
// be clicked while it films (the take is long enough), or record a second take.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const win = process.platform === 'win32';
const forgeExe = (env) => env.FORGE_EXE || path.join(os.homedir(), 'AppData', 'Local', 'Vanilla Forge', 'Vanilla Forge.exe');

export default [
  {
    name: 'launcher',
    kind: 'desktop',
    title: 'The desktop launcher (Home, Workshop, Play Solo)',
    ready: () => (win ? true : 'desktop scenes need Windows'),
    async run(s) {
      s.start(win ? 'py' : 'python3', [...(win ? ['-3'] : []), 'launcher_gui.py'], s.root);
      await s.sleep(9000);
      await s.shot('home', 'Open Vanilla Launcher', 14);
    },
  },
  {
    name: 'forge',
    kind: 'desktop',
    title: 'Vanilla Forge (world editor, models, behaviour cards)',
    ready: (env) => (!win ? 'desktop scenes need Windows' : fs.existsSync(forgeExe(env)) ? true : `Forge not found at ${forgeExe(env)} (set FORGE_EXE)`),
    async run(s) {
      s.start(`"${forgeExe(s.env)}"`, [], path.dirname(forgeExe(s.env)));
      await s.sleep(10000);
      await s.shot('main', 'Vanilla Forge', 16);
    },
  },
];
