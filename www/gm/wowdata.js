// wowdata.js: read the game's own data files in the browser, from the server's /data/ endpoint.
//   DBC tables (ItemDisplayInfo, ItemSet, Spell) and BLP textures (item icons), decoded to canvases.
// Everything is fetched lazily and cached; the server marks /data/ files immutable, so the browser
// keeps them after the first load.

const cache = new Map();
const fetchBytes = (path) => {
  if (!cache.has(path)) {
    cache.set(
      path,
      fetch('/data/' + path).then((r) => {
        if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
        return r.arrayBuffer();
      }),
    );
  }
  return cache.get(path);
};

/** A parsed WDBC table: rows, fields, u32(row, field), i32, f32, str(row, field). */
export async function loadDbc(name) {
  const buf = await fetchBytes('dbfilesclient/' + name.toLowerCase());
  const b = new Uint8Array(buf);
  const dv = new DataView(buf);
  if (String.fromCharCode(b[0], b[1], b[2], b[3]) !== 'WDBC') throw new Error(name + ': not a DBC');
  const rows = dv.getUint32(4, true);
  const fields = dv.getUint32(8, true);
  const recSize = dv.getUint32(12, true);
  const strOff = 20 + rows * recSize;
  const dec = new TextDecoder('utf-8');
  const at = (r, f) => 20 + r * recSize + f * 4;
  return {
    rows,
    fields,
    u32: (r, f) => dv.getUint32(at(r, f), true),
    i32: (r, f) => dv.getInt32(at(r, f), true),
    f32: (r, f) => dv.getFloat32(at(r, f), true),
    str(r, f) {
      const o = strOff + dv.getUint32(at(r, f), true);
      let e = o;
      while (b[e]) e++;
      return dec.decode(b.subarray(o, e));
    },
    /** Map from the id in field 0 to the row index. */
    index() {
      const m = new Map();
      for (let r = 0; r < rows; r++) m.set(dv.getUint32(at(r, 0), true), r);
      return m;
    },
  };
}

// ── icons ─────────────────────────────────────────────────────────────────────────────────────
let displayIcons = null;
/** displayId -> icon name, from ItemDisplayInfo.dbc (field 5, InventoryIcon). */
export async function iconNames() {
  if (!displayIcons) {
    displayIcons = loadDbc('ItemDisplayInfo.dbc').then((d) => {
      const m = new Map();
      for (let r = 0; r < d.rows; r++) m.set(d.u32(r, 0), d.str(r, 5));
      return m;
    });
  }
  return displayIcons;
}

// DXT colour block -> 16 RGBA pixels into out (stride 4 px)
function rgb565(c) {
  return [((c >> 11) & 31) * 255 / 31, ((c >> 5) & 63) * 255 / 63, (c & 31) * 255 / 31];
}
function dxtColors(b, o, dxt1, outCols) {
  const c0 = b[o] | (b[o + 1] << 8);
  const c1 = b[o + 2] | (b[o + 3] << 8);
  const p0 = rgb565(c0);
  const p1 = rgb565(c1);
  outCols[0] = [...p0, 255];
  outCols[1] = [...p1, 255];
  if (c0 > c1 || !dxt1) {
    outCols[2] = [(2 * p0[0] + p1[0]) / 3, (2 * p0[1] + p1[1]) / 3, (2 * p0[2] + p1[2]) / 3, 255];
    outCols[3] = [(p0[0] + 2 * p1[0]) / 3, (p0[1] + 2 * p1[1]) / 3, (p0[2] + 2 * p1[2]) / 3, 255];
  } else {
    outCols[2] = [(p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2, (p0[2] + p1[2]) / 2, 255];
    outCols[3] = [0, 0, 0, 0];
  }
  return b[o + 4] | (b[o + 5] << 8) | (b[o + 6] << 16) | (b[o + 7] << 24);
}

/** Decode a BLP2 (1.12 textures) into {w, h, rgba}. Mip 0 only. */
export function decodeBlp(buf) {
  const b = new Uint8Array(buf);
  const dv = new DataView(buf);
  if (String.fromCharCode(b[0], b[1], b[2], b[3]) !== 'BLP2') throw new Error('not BLP2');
  const compression = b[8]; // 1 palette, 2 DXT, 3 raw BGRA
  const alphaDepth = b[9];
  const alphaType = b[10]; // DXT: 0 DXT1, 1 DXT3, 7 DXT5
  const w = dv.getUint32(12, true);
  const h = dv.getUint32(16, true);
  const off = dv.getUint32(20, true);
  const size = dv.getUint32(84, true);
  const out = new Uint8ClampedArray(w * h * 4);
  if (compression === 1) {
    const pal = 148;
    const n = w * h;
    for (let i = 0; i < n; i++) {
      const p = pal + b[off + i] * 4;
      out[i * 4] = b[p + 2];
      out[i * 4 + 1] = b[p + 1];
      out[i * 4 + 2] = b[p];
      let a = 255;
      if (alphaDepth === 8) a = b[off + n + i];
      else if (alphaDepth === 1) a = (b[off + n + (i >> 3)] >> (i & 7)) & 1 ? 255 : 0;
      else if (alphaDepth === 4) a = ((b[off + n + (i >> 1)] >> ((i & 1) * 4)) & 15) * 17;
      out[i * 4 + 3] = a;
    }
  } else if (compression === 2) {
    const kind = alphaDepth <= 1 ? 1 : alphaType === 7 ? 5 : 3;
    const blockBytes = kind === 1 ? 8 : 16;
    const cols = [];
    let o = off;
    for (let by = 0; by < Math.max(1, h / 4); by++) {
      for (let bx = 0; bx < Math.max(1, w / 4); bx++, o += blockBytes) {
        const alpha = new Array(16).fill(255);
        let co = o;
        if (kind === 3) {
          for (let i = 0; i < 16; i++) alpha[i] = ((b[o + (i >> 1)] >> ((i & 1) * 4)) & 15) * 17;
          co = o + 8;
        } else if (kind === 5) {
          const a0 = b[o];
          const a1 = b[o + 1];
          const av = [a0, a1];
          if (a0 > a1) for (let i = 1; i < 7; i++) av.push(((7 - i) * a0 + i * a1) / 7);
          else {
            for (let i = 1; i < 5; i++) av.push(((5 - i) * a0 + i * a1) / 5);
            av.push(0, 255);
          }
          let bits = 0n;
          for (let i = 0; i < 6; i++) bits |= BigInt(b[o + 2 + i]) << BigInt(8 * i);
          for (let i = 0; i < 16; i++) alpha[i] = av[Number((bits >> BigInt(3 * i)) & 7n)];
          co = o + 8;
        }
        const idx = dxtColors(b, co, kind === 1, cols);
        for (let i = 0; i < 16; i++) {
          const x = bx * 4 + (i & 3);
          const y = by * 4 + (i >> 2);
          if (x >= w || y >= h) continue;
          const c = cols[(idx >>> (2 * i)) & 3];
          const p = (y * w + x) * 4;
          out[p] = c[0];
          out[p + 1] = c[1];
          out[p + 2] = c[2];
          out[p + 3] = kind === 1 ? c[3] : alpha[i];
        }
      }
    }
  } else if (compression === 3) {
    for (let i = 0; i < w * h; i++) {
      out[i * 4] = b[off + i * 4 + 2];
      out[i * 4 + 1] = b[off + i * 4 + 1];
      out[i * 4 + 2] = b[off + i * 4];
      out[i * 4 + 3] = b[off + i * 4 + 3];
    }
  } else throw new Error('BLP compression ' + compression);
  void size;
  return { w, h, rgba: out };
}

const iconUrls = new Map();
/** A data: URL (PNG) for an icon name like "INV_Helmet_03"; falls back to the question mark. */
export function iconUrl(name) {
  name = (name || 'INV_Misc_QuestionMark').toLowerCase();
  if (!iconUrls.has(name)) {
    iconUrls.set(
      name,
      fetchBytes(`interface/icons/${name}.blp`)
        .then((buf) => {
          const { w, h, rgba } = decodeBlp(buf);
          const c = document.createElement('canvas');
          c.width = w;
          c.height = h;
          c.getContext('2d').putImageData(new ImageData(rgba, w, h), 0, 0);
          return c.toDataURL();
        })
        .catch(() => (name === 'inv_misc_questionmark' ? '' : iconUrl('INV_Misc_QuestionMark'))),
    );
  }
  return iconUrls.get(name);
}

// ── item sets and spell text ──────────────────────────────────────────────────────────────────
let sets = null;
/** [{id, name, items:[ids], bonuses:[{pieces, spell}]}] from ItemSet.dbc. */
export async function itemSets() {
  if (!sets) {
    sets = loadDbc('ItemSet.dbc').then((d) => {
      const out = [];
      for (let r = 0; r < d.rows; r++) {
        const items = [];
        for (let f = 10; f < 27; f++) if (d.u32(r, f)) items.push(d.u32(r, f));
        const bonuses = [];
        for (let i = 0; i < 8; i++) if (d.u32(r, 27 + i)) bonuses.push({ spell: d.u32(r, 27 + i), pieces: d.u32(r, 35 + i) });
        out.push({ id: d.u32(r, 0), name: d.str(r, 1), items, bonuses });
      }
      return out;
    });
  }
  return sets;
}

let spells = null;
/** Text of a spell's description with $s1-$s3 filled in (Spell.dbc: name 120, description 138). */
export async function spellText(id) {
  if (!spells) spells = loadDbc('Spell.dbc').then((d) => ({ d, idx: d.index() }));
  const { d, idx } = await spells;
  const r = idx.get(id);
  if (r === undefined) return '';
  const value = (n) => {
    const bp = d.i32(r, 76 + n);
    const die = d.i32(r, 64 + n);
    return die > 1 ? `${bp + 1} to ${bp + die}` : `${bp + Math.max(1, die)}`;
  };
  let text = d.str(r, 138) || d.str(r, 120);
  text = text
    .replace(/\$s([1-3])/g, (_, n) => value(Number(n) - 1))
    .replace(/\$o([1-3])/g, (_, n) => value(Number(n) - 1))
    .replace(/\$\d*[a-z]\d?/gi, '')
    .replace(/\s+/g, ' ')
    .trim();
  return text;
}
