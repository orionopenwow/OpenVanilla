// Website scenes: the home page and the feature pages on openvanilla.app (SITE_URL to film a local
// copy, e.g. http://127.0.0.1:8000). One video each.
const site = (env) => (env.SITE_URL || 'https://openvanilla.app').replace(/\/$/, '');
// never in a trailer: the tip-jar nudge and pill, toasts
const TIDY = ['#owNudge', '#owSupportPill', '#wowToast', '.ow-nudge'];

async function open(s, page) {
  await s.goto(site(s.env) + '/' + page);
  await s.tidy(TIDY);
  await s.page.mouse.move(s.W * 0.62, s.H * 0.55);
  await s.sleep(2500);                    // fonts, hero art and the first animations settle
}

// a slow pass down a page, stopping on each heading
async function tour(s, name, headings, per = 3.2) {
  await s.shot(name, 1, async () => {
    for (const h of headings) {
      await s.scrollTo(h, 2200);
      await s.sleep(per * 1000);
    }
  });
}

export default [
  {
    name: 'site-home',
    title: 'The website: hero, realms, launcher, Forge, Agents, Herald, What\'s next',
    async run(s) {
      await open(s, '');
      await s.shot('hero', 9, async () => {            // the book, the magic, the sky
        await s.sleep(1500);
        await s.glide(s.W * 0.5, s.H * 0.42, 1800);       // the hover lift
        await s.sleep(2500);
        await s.glide(s.W * 0.7, s.H * 0.6, 1600);
      });
      await s.shot('realms', 6, async () => { await s.scrollTo('#realmListSection', 2200, 120); await s.sleep(1500); await s.point('#realmListSection a, #realmListSection button', 900); });
      await tour(s, 'features', ['#server-software', '#desktop-launcher', '.cp-addons'], 3.4);
      await s.shot('forge-agents', 1, async () => {
        await s.scrollTo('#forge', 2400); await s.sleep(3500);
        await s.scrollTo('#agents', 2400); await s.sleep(4500);   // the inn GIF plays
      });
      await tour(s, 'herald-next', ['#herald', '#whats-next'], 3.6);
    },
  },
  {
    name: 'site-forge',
    title: 'Vanilla Forge page',
    async run(s) {
      await open(s, 'forge.html');
      await s.shot('top', 6, async () => { await s.sleep(1500); await s.glide(s.W * 0.55, s.H * 0.5, 1500); });
      await tour(s, 'pages', ['h2', 'h2 >> nth=1', 'h2 >> nth=2', 'h2 >> nth=3'], 3);
    },
  },
  {
    name: 'site-agents',
    title: 'Vanilla Agents page',
    async run(s) {
      await open(s, 'agents.html');
      await s.shot('top', 8, async () => { await s.sleep(5000); });   // the hero GIF
      await tour(s, 'pages', ['h2', 'h2 >> nth=1', 'h2 >> nth=2', 'h2 >> nth=3'], 3.2);
    },
  },
  {
    name: 'site-herald',
    title: 'Herald page',
    async run(s) {
      await open(s, 'herald.html');
      await s.shot('top', 6, async () => { await s.sleep(4000); });
      await tour(s, 'pages', ['h2', 'h2 >> nth=1', 'h2 >> nth=2', 'h2 >> nth=3'], 3);
    },
  },
  {
    name: 'site-workshop',
    title: 'Workshop (addons) and the manual',
    async run(s) {
      await open(s, 'workshop.html');
      await s.shot('workshop', 8, async () => { await s.sleep(1200); await s.scrollTo(700, 3000); await s.sleep(2500); });
      await s.goto(site(s.env) + '/manual/index.html'); await s.tidy(TIDY); await s.sleep(1500);
      await s.shot('manual', 7, async () => { await s.sleep(1000); await s.scrollTo(600, 3000); });
    },
  },
  {
    name: 'site-host',
    title: 'Host a realm and Play Solo pages',
    async run(s) {
      await open(s, 'host.html');
      await s.shot('host', 8, async () => { await s.sleep(1500); await s.scrollTo(800, 3500); });
      await open(s, 'solo.html');
      await s.shot('solo', 8, async () => { await s.sleep(1500); await s.scrollTo(800, 3500); });
    },
  },
];
