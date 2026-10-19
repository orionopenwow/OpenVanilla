// examples/hud.js — a web HUD on top of the canvas, in plain DOM: who you are and where, your
// target, the nearest units with distance and bearing, and the last few chat lines with how
// far away the speaker is. `?bridge=hud` on the dev page mounts it; it is the proximity-chat
// prerequisite made visible. Everything here is `wenilla.state` and two listeners.
import { wenilla } from '../bridge.js';

const el = document.createElement('div');
el.id = 'wenilla-hud';
el.style.cssText = `
  position: fixed; left: 0; top: 0; z-index: 9; max-width: 22rem; padding: .4rem .6rem;
  color: #ddd; background: rgba(0,0,0,.55); border-bottom-right-radius: 6px;
  font: 12px/1.35 ui-monospace, monospace; pointer-events: none; white-space: pre;`;
document.body.appendChild(el);

const chat = [];
wenilla.on('chat', (c) => {
  if (!['SAY', 'YELL', 'EMOTE', 'WHISPER', 'PARTY'].includes(c.kind)) return;
  const speaker = wenilla.state?.units?.find((u) => u.guid === c.senderGuid);
  const dist = speaker ? `${speaker.dist.toFixed(0)}yd` : c.senderGuid ? '?yd' : '';
  chat.push(`[${c.kind}] ${c.sender} ${dist}: ${c.text}`);
  if (chat.length > 5) chat.shift();
});

const deg = (r) => `${((r * 180) / Math.PI).toFixed(0)}°`;
const bar = (a, b) => (b ? `${a}/${b}` : '-');

wenilla.on('frame', (s) => {
  const lines = [];
  const me = s.self;
  if (!me) {
    lines.push(`wenilla · ${s.session.state}${s.session.connected ? '' : ' (offline)'}`);
  } else {
    lines.push(
      `${me.name ?? '?'} L${me.level} ${me.class ?? ''}  hp ${bar(me.health, me.maxHealth)}  ` +
        `${me.inCombat ? '⚔ ' : ''}${me.dead ? '☠ ' : ''}${me.casting ? `casting ${me.casting.spellId} ` : ''}`,
    );
    lines.push(
      `${s.zone?.name ?? `map ${s.map.id}`}${s.zone?.subzone ? ' · ' + s.zone.subzone : ''}  ` +
        `(${me.pos.map((v) => v.toFixed(1)).join(', ')}) ${deg(me.facing)}`,
    );
    if (s.target) {
      lines.push(
        `target: ${s.target.name ?? s.target.guid} L${s.target.level} ` +
          `${bar(s.target.health, s.target.maxHealth)} ${s.target.dist.toFixed(0)}yd ` +
          `${s.target.hostile ? 'hostile' : s.target.friendly ? 'friendly' : 'neutral'}`,
      );
    }
    for (const u of s.units.slice(0, 5)) {
      lines.push(
        `  ${u.isPlayer ? '@' : ' '}${(u.name ?? u.kind).padEnd(14)} ${u.dist.toFixed(0).padStart(3)}yd ` +
          `${deg(wenilla.bearingTo(u)).padStart(5)} ${u.dead ? '☠' : u.hostile ? '!' : ''}`,
      );
    }
    if (s.units.length > 5) lines.push(`  … ${s.units.length - 5} more in range`);
  }
  if (chat.length) lines.push('', ...chat);
  el.textContent = lines.join('\n');
});
