// The browser game on the realm (REALM_URL, default https://play.openvanilla.app).
//  game-start: the sign-in page, "Play free as a guest", the loading screen, the character screens.
//  game-world: in the world with the bot login (OWBOT_USER / OWBOT_PASS in .env): the open world,
//              the addon suite, World chat, the expanded chat, the bug button, the welcome.
// Uses the page's game hooks (window.wenilla: lua, hold, release, look) like tools/herald_film.mjs.
const realm = (env) => (env.REALM_URL || 'https://play.openvanilla.app').replace(/\/$/, '');

async function screen(s) { return s.page.evaluate(() => window.wenilla?.state?.session?.state || null).catch(() => null); }
const lua = (s, code) => s.page.evaluate((c) => window.wenilla.lua(c, 8000), code).catch((e) => ({ error: String(e.message || e) }));
const hold = (s, c) => s.page.evaluate((x) => window.wenilla.hold(x), c).catch(() => {});
const release = (s, c) => s.page.evaluate((x) => window.wenilla.release(x), c).catch(() => {});
const toggle = async (s, code, open = 1600) => { await lua(s, `pcall(function() ${code} end)`); await s.sleep(open); await lua(s, `pcall(function() ${code} end)`); await s.sleep(300); };

async function orbit(s, dx, dy = 0, steps = 40) {
  const cx = s.W / 2, cy = s.H / 2;
  await s.page.mouse.move(cx, cy); await s.page.mouse.down({ button: 'left' });
  for (let i = 1; i <= steps; i++) { await s.page.mouse.move(cx + (dx * i) / steps, cy + (dy * i) / steps); await s.sleep(16); }
  await s.page.mouse.up({ button: 'left' });
}
async function zoom(s, clicks) { await s.page.mouse.move(s.W / 2, s.H / 2); for (let i = 0; i < Math.abs(clicks); i++) { await s.page.mouse.wheel(0, Math.sign(clicks) * 120); await s.sleep(40); } }

async function untilScreen(s, want, secs) {
  for (let i = 0; i < secs; i++) { const v = await screen(s); if (want.includes(v)) return v; await s.sleep(1000); }
  return screen(s);
}

export default [
  {
    name: 'game-start',
    title: 'Play in the browser: sign-in page, guest start, loading, character screens',
    async run(s) {
      await s.goto(realm(s.env) + '/login');
      await s.sleep(2500);
      await s.shot('signin', 8, async () => {
        await s.sleep(1800);
        await s.point('text=Sign in with Discord', 1200); await s.sleep(1200);
        await s.point('text=Play free as a guest', 1000);
      });
      await s.shot('loading', 20, async () => {
        await s.click('text=Play free as a guest', 400);
        await untilScreen(s, ['login', 'charselect', 'charcreate', 'inworld'], 18);
      });
      await s.cursor(false);
      const v = await untilScreen(s, ['charselect', 'charcreate', 'inworld'], 240);   // the first download
      s.log(`  guest reached: ${v}`);
      await s.shot('characters', 10, async () => { await s.sleep(2000); await s.page.mouse.move(s.W * 0.3, s.H * 0.5); });
    },
  },
  {
    name: 'game-world',
    title: 'In the world: the open world, addons, World chat, expanded chat, bug button, welcome',
    ready: (env) => (env.OWBOT_USER && env.OWBOT_PASS ? true : 'needs OWBOT_USER and OWBOT_PASS in .env (a realm login with a character)'),
    async run(s) {
      await s.goto(realm(s.env) + '/login');
      await s.page.fill('input[name=username]', s.env.OWBOT_USER).catch(() => {});
      await s.page.fill('input[name=password]', s.env.OWBOT_PASS).catch(() => {});
      await s.page.click('form[action="/login"] [type=submit]').catch(() => {});
      await s.cursor(false);
      for (let i = 0; i < 600; i++) {
        const v = await screen(s);
        if (v === 'inworld') break;
        if (v === 'charselect') { await s.page.focus('#benilla').catch(() => {}); await s.page.keyboard.press('Enter'); await s.sleep(5000); }
        await s.sleep(1000);
      }
      if ((await screen(s)) !== 'inworld') throw new Error('never got into the world');
      await s.sleep(12000);
      await lua(s, 'pcall(function() SetCVar("cameraDistanceMax", 30) end)');
      await s.page.mouse.move(s.W / 2, s.H / 2);

      // the world: no interface, the camera swings round, then a run down the road
      await lua(s, 'UIParent:Hide()');
      await zoom(s, 8);
      await s.shot('world', 10, async () => { await orbit(s, s.W * 1.2, -80, 160); });
      await s.shot('run', 9, async () => {
        await hold(s, 'MOVEFORWARD');
        for (let i = 0; i < 6; i++) { await s.page.evaluate((y) => window.wenilla.look(y), (i % 2 ? 1 : -1) * 0.15); await s.sleep(1300); }
        await release(s, 'MOVEFORWARD');
      });
      await lua(s, 'UIParent:Show()');
      await zoom(s, -3);

      // the addon suite: bags, character, spellbook, quests, map
      await s.shot('addons', 12, async () => {
        await s.sleep(600);
        for (const c of ['OpenAllBags()', 'ToggleCharacter("PaperDollFrame")', 'ToggleSpellBook("spell")', 'ToggleQuestLog()', 'ToggleWorldMap()']) await toggle(s, c, 1700);
        await lua(s, 'pcall(function() CloseAllBags() end)');
      });
      // World chat (linked to Discord) and the expanded history
      await s.shot('chat', 12, async () => {
        await lua(s, 'pcall(function() CPChat:ViewWorld() end)'); await s.sleep(2500);
        await lua(s, 'pcall(function() CPChat:OpenExpanded() end)'); await s.sleep(3500);
        await lua(s, 'pcall(function() CPChat:ToggleExpandSize() end)'); await s.sleep(2500);
        await lua(s, 'pcall(function() CPChat:ToggleExpandSize(); CPChatExpanded:Hide() end)');
        await lua(s, 'pcall(function() CPChat:LeaveWorld() end)');
      });
      // the bug button and the first-login welcome
      await s.shot('help', 9, async () => {
        await lua(s, 'pcall(function() WenillaCore.Bugs.Open() end)'); await s.sleep(3500);
        await lua(s, 'pcall(function() WenillaCore_BugFrame:Hide() end)'); await s.sleep(400);
        await lua(s, 'pcall(function() SlashCmdList["WNLWELCOME"]("") end)'); await s.sleep(3500);
        await lua(s, 'pcall(function() CloseAllWindows() end)');
      });
      await s.shot('finale', 7, async () => { await lua(s, 'UIParent:Hide(); DoEmote("WAVE")'); await orbit(s, s.W * 0.6, -60, 90); await lua(s, 'DoEmote("CHEER")'); });
      await lua(s, 'UIParent:Show()');
    },
  },
];
