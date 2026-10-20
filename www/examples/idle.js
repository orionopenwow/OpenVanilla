// examples/idle.js — the smallest "idle-RPG" loop: pick the nearest hostile, attack it, cast
// something while it lives, sit when hurt. A sketch of the control API, not a bot; adjust the
// spell and the thresholds. Run with `import('./examples/idle.js')` or `?bridge=idle`.
import { wenilla } from '../bridge.js';

const SPELL = null; // e.g. 'Frostbolt' — null means auto-attack only
const REST_BELOW = 0.35;

let resting = false;
export const idle = {
  running: true,
  stop() {
    this.running = false;
    wenilla.releaseAll();
  },
};

setInterval(async () => {
  if (!idle.running) return;
  const s = wenilla.state;
  const me = s?.self;
  if (!me || me.dead || me.ghost) return;

  const hurt = me.health / Math.max(1, me.maxHealth) < REST_BELOW;
  if (!me.inCombat && hurt) {
    if (!resting) {
      wenilla.chat('/sit');
      resting = true;
    }
    return;
  }
  if (resting && !hurt) {
    wenilla.chat('/stand');
    resting = false;
  }

  const t = s.target;
  if (!t || t.dead || !t.hostile) {
    wenilla.fire('TARGETNEARESTENEMY');
    return;
  }
  if (!me.inCombat) wenilla.fire('ATTACKTARGET');
  if (SPELL && !me.casting) {
    await wenilla.lua(`CastSpellByName(${JSON.stringify(SPELL)})`).catch(() => {});
  }
}, 500);
