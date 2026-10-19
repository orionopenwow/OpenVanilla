// The World screen's 3D view: the tile's ground as a mesh (the 129 × 129 outer vertices of its
// 256 map chunks) with the 2D map draped over it (relief or the baked minimap, the overlays
// and the brush ring included), water as sheets at their surface, and the doodads as pins.
// Tools work the same as on the 2D map: the pointer is picked on the ground.
import * as THREE from './vendor/three.module.min.js';
import { OrbitControls } from './vendor/OrbitControls.js';
import { TransformControls } from './vendor/TransformControls.js';

export function createTerrain(canvas) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  // a daylight sky: blue overhead, a warm haze at the horizon the far ground fades into
  const HORIZON = 0xcfc6ae, ZENITH = 0x5f86b4;
  renderer.setClearColor(HORIZON);
  const scene = new THREE.Scene();
  scene.fog = new THREE.Fog(HORIZON, 650, 1700);
  // one fog for everything (the ground and water shaders share these): it starts beyond what
  // you're looking at, however far out the camera is
  const fogNearU = { value: 650 }, fogFarU = { value: 1700 };
  {
    const sky = new THREE.Mesh(new THREE.SphereGeometry(3500, 32, 16), new THREE.ShaderMaterial({
      side: THREE.BackSide, depthWrite: false, fog: false,
      uniforms: { top: { value: new THREE.Color(ZENITH) }, middle: { value: new THREE.Color(0x8fb0cf) }, bottom: { value: new THREE.Color(HORIZON) } },
      vertexShader: 'varying vec3 vP; void main() { vP = normalize(position); vec4 p = modelViewMatrix * vec4(position, 1.0); gl_Position = projectionMatrix * p; gl_Position.z = gl_Position.w; }',
      fragmentShader: 'uniform vec3 top; uniform vec3 middle; uniform vec3 bottom; varying vec3 vP; void main() { float h = clamp(vP.y * 1.6 + 0.05, 0.0, 1.0); vec3 c = h < 0.35 ? mix(bottom, middle, h / 0.35) : mix(middle, top, (h - 0.35) / 0.65); gl_FragColor = vec4(c, 1.0);\n#include <colorspace_fragment>\n}',
    }));
    sky.renderOrder = -1; sky.frustumCulled = false; scene.add(sky);
    scene.userData.sky = sky;
  }
  const camera = new THREE.PerspectiveCamera(50, 1, 1, 6000);
  const controls = new OrbitControls(camera, canvas);
  controls.enableDamping = true;
  // left button is the tool; right turns, middle pans, the wheel zooms
  controls.mouseButtons = { LEFT: null, MIDDLE: THREE.MOUSE.PAN, RIGHT: THREE.MOUSE.ROTATE };
  controls.maxPolarAngle = Math.PI * 0.49;
  controls.maxDistance = 1500; controls.minDistance = 4;
  const hemi = new THREE.HemisphereLight(0xe8e0d0, 0x302818, 1.1); scene.add(hemi);
  const sun = new THREE.DirectionalLight(0xfff1d8, 1.6); sun.position.set(-300, 500, -300); scene.add(sun);
  // the light of the place and hour (the Light editor's time of day): shared by the ground and water shaders
  const fogSRGB = { value: new THREE.Vector3(0xcf / 255, 0xc6 / 255, 0xae / 255) }, fogLin = { value: new THREE.Color(0xcfc6ae) };
  const ambU = { value: new THREE.Vector3(0.6, 0.6, 0.6) }, sunU = { value: new THREE.Vector3(0.62, 0.62, 0.62) };
  const rgb = (c) => [((c >> 16) & 255) / 255, ((c >> 8) & 255) / 255, (c & 255) / 255];
  function setSky(k) {
    if (!k) return;
    const sky = scene.userData.sky.material.uniforms;
    sky.top.value.setHex(k.top); sky.middle.value.setHex(k.middle); sky.bottom.value.setHex(k.horizon);
    scene.fog.color.setHex(k.fog); fogLin.value.setHex(k.fog); renderer.setClearColor(k.fog);
    fogSRGB.value.set(...rgb(k.fog));
    // the game's sun is strong and coloured: tempered toward white so textures keep their own colour
    const a = rgb(k.ambient), d = rgb(k.sun);
    ambU.value.set(...a.map((x) => 0.25 + x * 0.75));
    sunU.value.set(...d.map((x) => 0.35 + x * 0.45));
    hemi.color.setRGB(...a.map((x) => 0.4 + x * 0.9)); hemi.groundColor.setRGB(...a.map((x) => x * 0.35));
    sun.color.setRGB(...d.map((x) => 0.5 + x * 0.6));
  }

  // True View: the game's own doodads and buildings as real meshes (loaded on demand, shared)
  const models = new THREE.Group(); scene.add(models);
  const meshes = new Map(), textures = new Map();
  let fetchMesh = null, fetchTexture = null, modelsOn = false, modelsFor = null;
  const bytes = (b64) => { const s = atob(b64), u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i); return u.buffer; };
  function textureFor(path) {
    if (!path) return null;
    const key = path.toLowerCase();
    if (!textures.has(key)) {
      const tex = new THREE.Texture();
      tex.wrapS = tex.wrapT = THREE.RepeatWrapping; tex.colorSpace = THREE.SRGBColorSpace; tex.flipY = false; tex.anisotropy = Math.min(8, renderer.capabilities.getMaxAnisotropy());
      textures.set(key, tex);
      fetchTexture(path).then((url) => { const im = new Image(); im.onload = () => { tex.image = im; tex.needsUpdate = true; }; im.src = url; }).catch(() => {});
    }
    return textures.get(key);
  }
  // ---- animation: a model's bones standing (or running), skinned on the GPU; every copy of a
  // model moves together (one set of bone matrices per model, in a small float texture)
  const animated = new Set(), animOf = new WeakMap();
  const _m = new THREE.Matrix4(), _q = new THREE.Quaternion(), _q2 = new THREE.Quaternion(), _v = new THREE.Vector3(), _s = new THREE.Vector3(), _p = new THREE.Matrix4();
  function key(tr, time, len, width, out) {
    const T = tr.loop ? time % tr.loop : time % len, t = tr.t, v = tr.v, n = t.length;
    let k = 0;
    while (k < n - 1 && t[k + 1] <= T) k++;
    if (k >= n - 1 || tr.i === 0) { for (let c = 0; c < width; c++) out[c] = v[k * width + c]; return out; }
    const f = (T - t[k]) / Math.max(1, t[k + 1] - t[k]);
    for (let c = 0; c < width; c++) out[c] = v[k * width + c] + (v[(k + 1) * width + c] - v[k * width + c]) * f;
    if (width === 4) {
      // quaternions the short way round
      const dot = v[k * 4] * v[(k + 1) * 4] + v[k * 4 + 1] * v[(k + 1) * 4 + 1] + v[k * 4 + 2] * v[(k + 1) * 4 + 2] + v[k * 4 + 3] * v[(k + 1) * 4 + 3];
      if (dot < 0) for (let c = 0; c < 4; c++) out[c] = v[k * 4 + c] - (v[(k + 1) * 4 + c] + v[k * 4 + c]) * f;
      const l = Math.hypot(out[0], out[1], out[2], out[3]) || 1; for (let c = 0; c < 4; c++) out[c] /= l;
    }
    return out;
  }
  function makeAnim(m, g) {
    const a = m.anim, nb = a.bones.length, sk = new Uint8Array(bytes(m.skin)), nv = m.verts;
    const w = new Uint8Array(nv * 4), ix = new Uint8Array(nv * 4);
    for (let i = 0; i < nv; i++) for (let c = 0; c < 4; c++) { w[i * 4 + c] = sk[i * 8 + c]; ix[i * 4 + c] = Math.min(nb - 1, sk[i * 8 + 4 + c]); }
    g.setAttribute('skinW', new THREE.BufferAttribute(w, 4, true));
    g.setAttribute('skinIdx', new THREE.BufferAttribute(ix, 4, false));
    const data = new Float32Array(nb * 16), tex = new THREE.DataTexture(data, nb * 4, 1, THREE.RGBAFormat, THREE.FloatType);
    tex.needsUpdate = true;
    const A = { a, nb, data, tex, world: Array.from({ length: nb }, () => new THREE.Matrix4()), seq: 'stand', t0: performance.now() * Math.random(), live: 0 };
    tick(A, 0);
    return A;
  }
  const tv = [0, 0, 0], tq = [0, 0, 0, 1], ts = [1, 1, 1];
  function tick(A, now) {
    const seq = A.a.seqs[A.seq] || A.a.seqs.stand || Object.values(A.a.seqs)[0], time = now - A.t0;
    for (let i = 0; i < A.nb; i++) {
      const b = A.a.bones[i], tr = seq.bones[i] || {};
      const t = tr.t ? key(tr.t, time, seq.len, 3, tv) : [0, 0, 0];
      const r = tr.r ? key(tr.r, time, seq.len, 4, tq) : [0, 0, 0, 1];
      const sc = tr.s ? key(tr.s, time, seq.len, 3, ts) : [1, 1, 1];
      _q.set(r[0], r[1], r[2], r[3]); _s.set(sc[0], sc[1], sc[2]); _v.set(t[0] + b.pv[0], t[1] + b.pv[1], t[2] + b.pv[2]);
      _m.compose(_v, _q, _s);
      _p.makeTranslation(-b.pv[0], -b.pv[1], -b.pv[2]); _m.multiply(_p);
      if (b.p >= 0 && b.p < i) A.world[i].multiplyMatrices(A.world[b.p], _m); else A.world[i].copy(_m);
      A.data.set(A.world[i].elements, i * 16);
    }
    A.tex.needsUpdate = true;
  }
  function skinned(mat, A) {
    mat.onBeforeCompile = (sh) => {
      sh.uniforms.boneTex = { value: A.tex };
      sh.vertexShader = `attribute vec4 skinW; attribute vec4 skinIdx; uniform highp sampler2D boneTex;
        mat4 boneM(float i) { int x = int(i) * 4; return mat4(texelFetch(boneTex, ivec2(x, 0), 0), texelFetch(boneTex, ivec2(x + 1, 0), 0), texelFetch(boneTex, ivec2(x + 2, 0), 0), texelFetch(boneTex, ivec2(x + 3, 0), 0)); }
        mat4 skinMat() { float s = skinW.x + skinW.y + skinW.z + skinW.w; if (s < 0.01) return mat4(1.0); return (skinW.x * boneM(skinIdx.x) + skinW.y * boneM(skinIdx.y) + skinW.z * boneM(skinIdx.z) + skinW.w * boneM(skinIdx.w)) / s; }
        ` + sh.vertexShader
        .replace('#include <beginnormal_vertex>', '#include <beginnormal_vertex>\n objectNormal = normalize(mat3(skinMat()) * objectNormal);')
        .replace('#include <begin_vertex>', '#include <begin_vertex>\n transformed = (skinMat() * vec4(transformed, 1.0)).xyz;');
    };
    mat.customProgramCacheKey = () => 'm2skin';
  }
  function animate(now) {
    const wa = walkerModel && animOf.get(walkerModel.geometry);
    if (wa) wa.seq = W.on && W.moving ? 'run' : 'stand';
    for (const A of animated) tick(A, now);
  }

  function template(m, path) {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(new Float32Array(bytes(m.pos)), 3));
    g.setAttribute('normal', new THREE.BufferAttribute(new Float32Array(bytes(m.normal)), 3));
    g.setAttribute('uv', new THREE.BufferAttribute(new Float32Array(bytes(m.uv)), 2));
    g.setIndex(new THREE.BufferAttribute(m.index32 ? new Uint32Array(bytes(m.index32)) : new Uint16Array(bytes(m.index)), 1));
    const mats = [];
    // a character model carries every hairstyle and piece of clothing: draw the bare defaults
    const character = m.batches.some((b) => b.replace === 1);
    m.batches.forEach((b, i) => {
      while (mats.length < i) mats.push(null);
      const g0 = b.geoset;
      if (character && g0 != null && !(g0 === 0 || g0 === 1 || (g0 >= 100 && g0 % 100 === 1))) return;
      g.addGroup(b.start, b.count, i);
      const map = textureFor(b.texture);
      const blended = b.blend >= 2;
      const opts = { map, color: map ? 0xffffff : (b.replace ? 0xc8bca8 : 0x8a8070), side: b.two_sided || m.kind === 'wmo' ? THREE.DoubleSide : THREE.FrontSide, alphaTest: b.blend === 1 ? 0.5 : 0, transparent: blended, depthWrite: !blended };
      if (b.blend >= 3) opts.blending = THREE.AdditiveBlending;
      const mat = b.unlit ? new THREE.MeshBasicMaterial(opts) : new THREE.MeshLambertMaterial(opts);
      // a character's skin: the game's first skin colour for that race, when the game has it
      const race = b.replace === 1 && /^character\\(\w+)\\(male|female)\\/i.exec(path || '');
      if (race) {
        const skin = `Character\\${race[1]}\\${race[2]}\\${race[1]}${race[2]}Skin00_00.blp`;
        fetchTexture(skin).then((url) => { const im = new Image(); im.onload = () => { const t = new THREE.Texture(im); t.colorSpace = THREE.SRGBColorSpace; t.flipY = false; t.needsUpdate = true; mat.map = t; mat.color.set(0xffffff); mat.needsUpdate = true; }; im.src = url; }).catch(() => {});
      }
      mats.push(mat);
    });
    const mesh = new THREE.Mesh(g, mats);
    if (m.particles?.length) partsOf.set(g, m.particles);
    if (m.sets?.length) setsOf.set(g, m.sets);
    if (m.anim && m.skin) {
      try {
        const A = makeAnim(m, g);
        mats.forEach((x) => x && skinned(x, A));
        animated.add(A); animOf.set(g, A);
        // bounding boxes from the rest pose; a moving model can reach a little past them
        g.computeBoundingSphere(); g.boundingSphere.radius *= 1.5;
      } catch (e) { /* the model stands still */ }
    }
    return mesh;
  }
  function meshFor(path) {
    const key = path.toLowerCase();
    if (!meshes.has(key)) meshes.set(key, fetchMesh(path).then((m) => template(m, path)).catch(() => null));
    return meshes.get(key);
  }
  // one placed model: turned `yaw` degrees the way the game turns them (file x = sin·x + cos·y,
  // file z = cos·x − sin·y, up = z), sized and moved to (u, h, v)
  // a model's place as the game sets it: turned about the up axis, leaning by its two other
  // rotations (the tile's rotation x and z), sized; the model's z-up turned to our y-up
  const _ry = new THREE.Matrix4(), _rz = new THREE.Matrix4(), _rx = new THREE.Matrix4(), CONV = new THREE.Matrix4().set(1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1);
  function objMatrix(m, u, h, v, yaw, scale, tilt) {
    if (!tilt || (!tilt[0] && !tilt[1])) {
      const a = yaw * Math.PI / 180, sn = Math.sin(a) * scale, cs = Math.cos(a) * scale;
      return m.set(sn, cs, 0, u, 0, 0, scale, h, cs, -sn, 0, v, 0, 0, 0, 1);
    }
    const d = Math.PI / 180;
    m.makeTranslation(u, h, v).multiply(_ry.makeRotationY((yaw - 90) * d)).multiply(_rz.makeRotationZ(tilt[0] * d)).multiply(_rx.makeRotationX(-tilt[1] * d)).multiply(CONV);
    return m.scale(_s.set(scale, scale, scale));
  }
  function placeModel(tpl, u, h, v, yaw, scale, tilt, set = 0) {
    const o = tpl.clone(); o.matrixAutoUpdate = false;
    objMatrix(o.matrix, u, h, v, yaw, scale, tilt);
    const ps = partsOf.get(tpl.geometry);
    if (ps) for (const em of ps) o.add(emitter(em, scale, animOf.get(tpl.geometry)));
    const sets = setsOf.get(tpl.geometry);
    if (sets) furnish(o, sets, set);
    return o;
  }
  // a building's furniture: its default doodad set and the one the placement picks, each doodad
  // in the building's own space (they come in as their models arrive)
  const setsOf = new WeakMap();
  function furnish(o, sets, set) {
    for (const k of [...new Set([0, set])]) {
      for (const d of sets[k]?.doodads || []) {
        meshFor(d.model.replace(/\.md[lx]$/i, '.m2')).then((t2) => {
          if (!t2 || !o.parent) return;
          const c = t2.clone();
          c.position.set(d.pos[0], d.pos[1], d.pos[2]); c.quaternion.set(d.rot[0], d.rot[1], d.rot[2], d.rot[3]); c.scale.setScalar(d.scale || 1);
          const ps = partsOf.get(t2.geometry);
          if (ps) for (const em of ps) c.add(emitter(em, d.scale || 1, animOf.get(t2.geometry)));
          o.add(c);
        });
      }
    }
  }

  // ---- particles: the game's fires, glows and sparks, simply (each emitter's first values; in
  // the model's own space, so they follow it). Each placed model runs its own.
  const partsOf = new WeakMap(), systems = new Set();
  const PMAX = 160;
  function emitter(em, scale, A) {
    const n = Math.min(PMAX, Math.ceil(em.rate * em.life * 1.3) + 2);
    const g = new THREE.BufferGeometry();
    const pos = new Float32Array(n * 3), col = new Float32Array(n * 4), size = new Float32Array(n), cell = new Float32Array(n);
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3)); g.setAttribute('pcolor', new THREE.BufferAttribute(col, 4));
    g.setAttribute('psize', new THREE.BufferAttribute(size, 1)); g.setAttribute('pcell', new THREE.BufferAttribute(cell, 1));
    const add = em.blend >= 3, tex = textureFor(em.texture);
    const mat = new THREE.ShaderMaterial({
      transparent: true, depthWrite: false, blending: add ? THREE.AdditiveBlending : THREE.NormalBlending,
      uniforms: { map: { value: tex }, grid: { value: new THREE.Vector2(em.cols, em.rows) }, px: { value: 600 }, scale: { value: scale }, hasMap: { value: 0 } },
      vertexShader: `attribute vec4 pcolor; attribute float psize; attribute float pcell; uniform float px; uniform float scale; varying vec4 vC; varying float vCell;
        void main() { vC = pcolor; vCell = pcell; vec4 mv = modelViewMatrix * vec4(position, 1.0); gl_Position = projectionMatrix * mv; gl_PointSize = psize * scale * px / max(1.0, -mv.z); }`,
      fragmentShader: `uniform sampler2D map; uniform vec2 grid; uniform float hasMap; varying vec4 vC; varying float vCell;
        void main() { if (vC.a <= 0.002) discard; vec2 pc = gl_PointCoord; vec2 c = vec2(mod(vCell, grid.x), floor(vCell / grid.x));
          vec4 t = hasMap > 0.5 ? texture2D(map, (c + pc) / grid) : vec4(1.0, 1.0, 1.0, 1.0 - smoothstep(0.2, 0.5, length(pc - 0.5)));
          gl_FragColor = vec4(t.rgb * vC.rgb, t.a * vC.a); }`,
    });
    const pts = new THREE.Points(g, mat); pts.frustumCulled = false;
    const S = { em, n, pos, col, size, cell, vel: new Float32Array(n * 3), age: new Float32Array(n).fill(1e9), life: new Float32Array(n), acc: Math.random(), pts, mat, g, A };
    systems.add(S);
    return pts;
  }
  const lerp = (a, b, t) => a + (b - a) * t;
  function stepParticles(dt) {
    const px = renderer.domElement.height / (2 * Math.tan(camera.fov * Math.PI / 360));
    for (const S of systems) {
      const p = S.pts;
      let root = p; while (root.parent) root = root.parent;
      if (root !== scene) { systems.delete(S); S.g.dispose(); S.mat.dispose(); continue; }
      p.getWorldPosition(_v);
      if (_v.distanceToSquared(camera.position) > 400 * 400) { S.g.setDrawRange(0, 0); continue; }
      S.g.setDrawRange(0, S.n); S.mat.uniforms.px.value = px * 2; // a particle's scale is half its width
      // a texture the game doesn't have (or hasn't arrived yet): soft round dots instead
      S.mat.uniforms.hasMap.value = S.mat.uniforms.map.value?.image ? 1 : 0;
      const e = S.em, life = Math.max(0.1, e.life);
      // spawn
      S.acc += e.rate * dt;
      for (let i = 0; i < S.n && S.acc >= 1; i++) {
        if (S.age[i] < S.life[i]) continue;
        S.acc -= 1; S.age[i] = 0; S.life[i] = life;
        S.pos[i * 3] = e.pos[0] + (Math.random() - 0.5) * e.len; S.pos[i * 3 + 1] = e.pos[1] + (Math.random() - 0.5) * e.wid; S.pos[i * 3 + 2] = e.pos[2];
        // an emitter on a moving bone (a swinging lantern, a waving torch): born where the bone is now
        const bw = S.A && e.bone < S.A.nb ? S.A.world[e.bone] : null;
        if (bw) { _v.set(S.pos[i * 3], S.pos[i * 3 + 1], S.pos[i * 3 + 2]).applyMatrix4(bw); S.pos[i * 3] = _v.x; S.pos[i * 3 + 1] = _v.y; S.pos[i * 3 + 2] = _v.z; }
        const th = (Math.random() * 2 - 1) * Math.min(Math.PI, e.vrange), ph = Math.random() * Math.max(0.0001, e.hrange);
        const sp = e.speed * (1 + (Math.random() * 2 - 1) * e.var);
        S.vel[i * 3] = Math.sin(th) * Math.cos(ph) * sp; S.vel[i * 3 + 1] = Math.sin(th) * Math.sin(ph) * sp; S.vel[i * 3 + 2] = Math.cos(th) * sp;
        S.cell[i] = Math.floor(Math.random() * e.rows * e.cols);
      }
      if (S.acc > 1) S.acc = 1;
      // move and colour
      const mid = Math.min(0.99, Math.max(0.01, e.mid || 0.5)), C = e.colors, K = e.scales;
      for (let i = 0; i < S.n; i++) {
        S.age[i] += dt;
        const t = S.age[i] / S.life[i];
        if (t >= 1) { S.col[i * 4 + 3] = 0; continue; }
        S.vel[i * 3 + 2] -= e.gravity * dt;
        for (let k = 0; k < 3; k++) S.pos[i * 3 + k] += S.vel[i * 3 + k] * dt;
        const [a, b, f] = t < mid ? [C[0], C[1], t / mid] : [C[1], C[2], (t - mid) / (1 - mid)];
        for (let k = 0; k < 3; k++) S.col[i * 4 + k] = lerp(a[k], b[k], f) / 255;
        S.col[i * 4 + 3] = lerp(a[3], b[3], f) / 255;
        S.size[i] = t < mid ? lerp(K[0], K[1], t / mid) : lerp(K[1], K[2], (t - mid) / (1 - mid));
      }
      for (const k of ['position', 'pcolor', 'psize', 'pcell']) S.g.attributes[k].needsUpdate = true;
    }
  }
  // a pin hides once its model is drawn (one that can't be read keeps its pin)
  let loaded = new Set();
  const artPins = (modelsShown) => pins.children.forEach((c) => { if (c.userData.art !== undefined) c.visible = !(modelsShown && loaded.has(c.userData.art)); });
  async function showModels(t) {
    const want = modelsOn && fetchMesh ? t : null;
    if (modelsFor === want) return;
    modelsFor = want;
    models.clear();
    if (!want) return;
    const list = [];
    let done = 0;
    for (const d of t.stock) if (d.path && !d.hidden) list.push([d.path, d.u, d.h, d.v, d.rot?.[1] || 0, d.scale || 1, null, d.uid, [d.rot?.[0] || 0, d.rot?.[2] || 0]]);
    for (const w of t.buildings || []) if (w.path && !w.hidden) list.push([w.path, w.u, w.h, w.v, w.rot?.[1] || 0, 1, null, w.uid, [w.rot?.[0] || 0, w.rot?.[2] || 0], w.set || 0]);
    for (const m of t.mine) if (m.path) list.push([m.path, m.u, m.h, m.v, m.placement?.turn || 0, m.placement?.scale || 1, m.placement?.uid, null, m.placement?.tilt, m.placement?.set || 0]);
    await Promise.all(list.map(async ([path, u, h, v, yaw, sc, uid, game, tilt, set]) => {
      const tpl = await meshFor(path);
      done++; if (modelsFor === want) onProgress?.(done, list.length);
      if (tpl && modelsFor === want) {
        const o = placeModel(tpl, u, h, v, yaw, sc, tilt, set);
        if (uid) o.userData = { uid, u, h, v, yaw, scale: sc, wmo: /\.wmo$/i.test(path) };
        else if (game != null) o.userData = { game, path };
        models.add(o); loaded.add(path.toLowerCase());
      }
    }));
    if (pins && modelsFor === want) artPins(true);
    if (modelsFor === want && selUid.length) select(selUid);
  }

  const N = 129;
  let size = 533.333, ground = null, water = null, pins = null, tex = null, heights = null, framed = false;
  const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();

  function buildGround(t) {
    const pos = new Float32Array(N * N * 3), uv = new Float32Array(N * N * 2);
    for (let i = 0; i < N; i++) for (let j = 0; j < N; j++) {
      const k = i * N + j;
      pos[k * 3] = j / 128 * size; pos[k * 3 + 1] = t.heights[k]; pos[k * 3 + 2] = i / 128 * size;
      uv[k * 2] = j / 128; uv[k * 2 + 1] = 1 - i / 128;
    }
    const idx = [];
    for (let i = 0; i < N - 1; i++) for (let j = 0; j < N - 1; j++) {
      const a = i * N + j, b = a + 1, c = a + N, d = c + 1;
      idx.push(a, c, b, b, c, d);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    g.setAttribute('uv', new THREE.BufferAttribute(uv, 2));
    g.setIndex(idx);
    g.computeVertexNormals();
    return g;
  }

  // water: clear in the shallows, deep blue where it's deep, rippling, catching the sun at a
  // glance; magma glows and churns, slime is murky green
  const waterTime = { value: 0 };
  function buildWater(t) {
    const pos = [], kind = [], depth = [];
    const cell = size / 128, H = t.heights;
    const ground = (u, v) => { const j = Math.max(0, Math.min(128, Math.round(u / size * 128))), i = Math.max(0, Math.min(128, Math.round(v / size * 128))); return H[i * N + j]; };
    const K = { water: 0, ocean: 1, magma: 2, slime: 3 };
    (t.water || []).forEach((w, k) => {
      if (!w) return;
      const kk = K[w.kind] ?? 0;
      for (let i = 0; i < 64; i++) {
        if (w.tiles[i] !== '1') continue;
        const tx = i % 8, ty = Math.floor(i / 8);
        const x0 = ((k % 16) * 8 + tx) * cell, z0 = (Math.floor(k / 16) * 8 + ty) * cell;
        // a sloped surface (angled water) has its own height at each corner
        const hy = (dx, dz) => (w.heights ? w.heights[(ty + dz) * 9 + tx + dx] : w.level);
        const q = [[0, 0], [0, 1], [1, 0], [1, 0], [0, 1], [1, 1]];
        for (const [dx, dz] of q) { const x = x0 + dx * cell, z = z0 + dz * cell, y = hy(dx, dz); pos.push(x, y, z); kind.push(kk); depth.push(Math.max(0, y - ground(x, z))); }
      }
    });
    if (!pos.length) return null;
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute('kind', new THREE.Float32BufferAttribute(kind, 1));
    g.setAttribute('depth', new THREE.Float32BufferAttribute(depth, 1));
    const mat = new THREE.ShaderMaterial({
      transparent: true, depthWrite: false, side: THREE.DoubleSide,
      uniforms: { time: waterTime, fogColor: fogLin, fogNear: fogNearU, fogFar: fogFarU },
      vertexShader: `attribute float kind; attribute float depth; varying float vKind; varying float vDepth; varying vec3 vW; varying float vFog;
        void main() { vKind = kind; vDepth = depth; vec4 w = modelMatrix * vec4(position, 1.0); vW = w.xyz; vec4 mv = viewMatrix * w; vFog = -mv.z; gl_Position = projectionMatrix * mv; }`,
      fragmentShader: `uniform float time; uniform vec3 fogColor; uniform float fogNear; uniform float fogFar;
        varying float vKind; varying float vDepth; varying vec3 vW; varying float vFog;
        float wave(vec2 p) { return sin(p.x * 0.35 + time * 1.3) * 0.5 + sin(p.y * 0.28 - time * 1.1) * 0.5 + sin((p.x + p.y) * 0.6 + time * 2.1) * 0.25; }
        void main() {
          vec2 p = vW.xz;
          float e = 0.6;
          vec3 n = normalize(vec3(wave(p - vec2(e, 0.0)) - wave(p + vec2(e, 0.0)), 6.0, wave(p - vec2(0.0, e)) - wave(p + vec2(0.0, e))));
          vec3 v = normalize(cameraPosition - vW);
          vec3 sun = normalize(vec3(-0.45, 0.75, -0.45));
          float fres = pow(1.0 - max(dot(n, v), 0.0), 3.0);
          float spec = pow(max(dot(reflect(-sun, n), v), 0.0), 60.0);
          float d = smoothstep(0.0, 9.0, vDepth);
          vec3 col; float a;
          if (vKind > 2.5) { col = mix(vec3(0.32, 0.5, 0.12), vec3(0.16, 0.3, 0.06), d); a = 0.85; }
          else if (vKind > 1.5) {
            float churn = wave(p * 0.7) * 0.5 + 0.5;
            col = mix(vec3(0.75, 0.18, 0.02), vec3(1.0, 0.62, 0.15), churn); a = 1.0; spec = 0.0; fres = 0.0;
          } else {
            vec3 shallow = vKind > 0.5 ? vec3(0.12, 0.42, 0.55) : vec3(0.22, 0.52, 0.58);
            vec3 deep = vKind > 0.5 ? vec3(0.02, 0.1, 0.24) : vec3(0.04, 0.17, 0.3);
            col = mix(shallow, deep, d);
            a = mix(0.35, 0.88, d);
          }
          col = mix(col, vec3(0.75, 0.82, 0.88), fres * 0.45) + vec3(1.0, 0.95, 0.8) * spec * 0.8;
          a = clamp(a + fres * 0.25 + spec, 0.0, 1.0);
          gl_FragColor = vec4(mix(col, fogColor, smoothstep(fogNear, fogFar, vFog)), a);
          #include <colorspace_fragment>
        }`,
    });
    return new THREE.Mesh(g, mat);
  }

  function buildPins(t) {
    const group = new THREE.Group();
    const stock = new THREE.MeshLambertMaterial({ color: 0x3a3428 });
    const mine = new THREE.MeshLambertMaterial({ color: 0xe2b65a, emissive: 0x3a2a08 });
    const small = new THREE.ConeGeometry(1.2, 4, 6), big = new THREE.ConeGeometry(2.5, 8, 8);
    for (const d of t.stock) { if (d.hidden) continue; const m = new THREE.Mesh(small, stock); m.position.set(d.u, d.h + 2, d.v); m.userData.art = (d.path || "").toLowerCase(); group.add(m); }
    for (const d of t.mine) { if (d.box) continue; const m = new THREE.Mesh(big, mine); m.position.set(d.u, heightAt(d.u, d.v) + 4, d.v); m.userData.art = (d.path || "").toLowerCase(); group.add(m); }
    // buildings: their boxes
    const boxOf = (b, colour, opacity) => {
      const g = new THREE.BoxGeometry(b[2] - b[0], Math.max(1, b[5] - b[4]), b[3] - b[1]);
      const m = new THREE.Mesh(g, new THREE.MeshLambertMaterial({ color: colour, transparent: true, opacity }));
      m.position.set((b[0] + b[2]) / 2, (b[4] + b[5]) / 2, (b[1] + b[3]) / 2);
      const edges = new THREE.LineSegments(new THREE.EdgesGeometry(g), new THREE.LineBasicMaterial({ color: colour }));
      m.add(edges);
      return m;
    };
    // spawns: creatures red, objects blue
    const cr = new THREE.MeshLambertMaterial({ color: 0xe06650 }), ob = new THREE.MeshLambertMaterial({ color: 0x6aa8e8 });
    const cone = new THREE.ConeGeometry(1.2, 3, 8), cube = new THREE.BoxGeometry(2, 2, 2);
    for (const x of t.spawns || []) {
      const m = new THREE.Mesh(x.table === 'creature' ? cone : cube, x.table === 'creature' ? cr : ob);
      m.position.set(x.u, heightAt(x.u, x.v) + 1.5, x.v); group.add(m);
    }
    for (const w of t.buildings || []) { const b = boxOf(w.box, 0x6b5f4a, 0.06); b.userData.art = (w.path || "").toLowerCase(); group.add(b); }
    for (const d of t.mine) if (d.box) group.add(boxOf(d.box, 0xe2b65a, 0.35));
    return group;
  }

  function heightAt(u, v) {
    if (!heights) return 0;
    const j = Math.max(0, Math.min(128, Math.round(u / size * 128))), i = Math.max(0, Math.min(128, Math.round(v / size * 128)));
    return heights[i * N + j];
  }
  // the ground's height between its vertices (for walking on it)
  function groundAt(u, v) {
    if (!heights) return 0;
    const x = Math.max(0, Math.min(127.999, u / size * 128)), z = Math.max(0, Math.min(127.999, v / size * 128));
    const j = Math.floor(x), i = Math.floor(z), fx = x - j, fz = z - i;
    const h = (a, b) => heights[a * N + b];
    return (h(i, j) * (1 - fx) + h(i, j + 1) * fx) * (1 - fz) + (h(i + 1, j) * (1 - fx) + h(i + 1, j + 1) * fx) * fz;
  }
  // the water's surface over (u, v), if there is water there
  function waterAt(u, v) {
    const w = lastTile?.water; if (!w) return null;
    const cell = size / 128, c = Math.floor(u / cell), r = Math.floor(v / cell);
    if (c < 0 || r < 0 || c > 127 || r > 127) return null;
    const k = Math.floor(r / 8) * 16 + Math.floor(c / 8), x = w[k];
    if (!x || x.tiles[(r % 8) * 8 + (c % 8)] !== '1') return null;
    if (!x.heights) return x.level;
    // sloped: the surface between the tile's corners
    const fx = u / cell - c, fz = v / cell - r, tx = c % 8, ty = r % 8, H = x.heights, at = (i, j) => H[(ty + j) * 9 + tx + i];
    return (at(0, 0) * (1 - fx) + at(1, 0) * fx) * (1 - fz) + (at(0, 1) * (1 - fx) + at(1, 1) * fx) * fz;
  }

  // ---- Lights: their spheres (where they start to fade, where they end) -------------------------
  const lightG = new THREE.Group(); scene.add(lightG);
  function setLights(list, selected, origin) {
    lightG.children.forEach((o) => o.geometry?.dispose()); lightG.clear();
    for (const l of list || []) {
      if (l.global) continue;
      const u = origin.y - l.y, v = origin.x - l.x, on = l.id === selected;
      // the picked light shows both spheres; the others only a faint ring where they start to fade
      if (on) {
        for (const [r, op] of [[l.start, 0.5], [l.end, 0.22]]) {
          if (!(r > 0)) continue;
          const m = new THREE.Mesh(new THREE.SphereGeometry(r, 28, 14), new THREE.MeshBasicMaterial({ color: 0xf3d189, wireframe: true, transparent: true, opacity: op, depthWrite: false }));
          m.position.set(u, l.z, v); lightG.add(m);
        }
      } else if (l.start > 0) {
        const ring = new THREE.Mesh(new THREE.RingGeometry(l.start * 0.985, l.start, 64), new THREE.MeshBasicMaterial({ color: 0x9fc4ff, transparent: true, opacity: 0.35, side: THREE.DoubleSide, depthWrite: false }));
        ring.rotation.x = -Math.PI / 2; ring.position.set(u, l.z, v); lightG.add(ring);
      }
    }
  }

  // ---- Selection: one of the pack's own models, with handles to move, turn and size it ----------
  // (the gizmo works on a stand-in; the model follows it; letting go reports where it ended up)
  const gizmo = new TransformControls(camera, canvas);
  gizmo.setSize(0.85); gizmo.setSpace('world'); scene.add(gizmo);
  const proxy = new THREE.Object3D(); scene.add(proxy);
  let sel = [], selUid = [], onGizmo = null, dragged = false, onProgress = null;
  const base = { c: new THREE.Vector3(), rot: 0, scale: 1 };
  const boxes = new THREE.Group(); scene.add(boxes);
  const UP = new THREE.Vector3(0, 1, 0);
  function placeObj(o, u, h, v, yaw, sc) {
    const a = yaw * Math.PI / 180, sn = Math.sin(a) * sc, cs = Math.cos(a) * sc;
    o.matrix.set(sn, cs, 0, u, 0, 0, sc, h, cs, -sn, 0, v, 0, 0, 0, 1);
    o.matrixWorldNeedsUpdate = true;
  }
  // where each selected model goes for the stand-in's move/turn/size about the selection's middle
  function moved() {
    const dθ = proxy.rotation.y - base.rot, k = proxy.scale.x / base.scale;
    return sel.map((o) => {
      const d = o.userData;
      const off = new THREE.Vector3(d.u, d.h, d.v).sub(base.c).applyAxisAngle(UP, dθ);
      off.x *= k; off.z *= k;
      const p = base.c.clone().add(off).add(proxy.position).sub(base.c);
      return { o, uid: d.uid, u: p.x, h: p.y, v: p.z, yaw: ((d.yaw + dθ * 180 / Math.PI) % 360 + 360) % 360, scale: d.wmo ? 1 : d.scale * k };
    });
  }
  function proxyToModel() {
    if (!sel.length) return;
    if (gizmo.mode === 'scale') {
      const sc = [proxy.scale.x, proxy.scale.y, proxy.scale.z];
      const k = sc.reduce((best, v) => (Math.abs(v - base.scale) > Math.abs(best - base.scale) ? v : best), base.scale);
      proxy.scale.setScalar(sel.every((o) => o.userData.wmo) ? base.scale : Math.max(0.05, k));
    }
    for (const m of moved()) placeObj(m.o, m.u, m.h, m.v, m.yaw, m.scale);
    boxes.children.forEach((b) => b.update());
  }
  gizmo.addEventListener('objectChange', proxyToModel);
  gizmo.addEventListener('dragging-changed', (e) => {
    controls.enabled = !e.value && !W.on;
    if (e.value) { dragged = true; return; }
    if (!sel.length) return;
    const out = moved();
    for (const m of out) Object.assign(m.o.userData, { u: m.u, h: m.h, v: m.v, yaw: m.yaw, scale: m.scale });
    onGizmo?.(out.map(({ uid, u, h, v, yaw, scale }) => ({ uid, u, h, v, yaw, scale })));
    select(selUid);
  });
  // select one or more of the pack's models (by uid): boxes round them, the handles at their middle
  function select(uids) {
    selUid = (Array.isArray(uids) ? uids : uids ? [uids] : []).filter(Boolean);
    sel = selUid.map((u) => models.children.find((o) => o.userData?.uid === u)).filter(Boolean);
    boxes.children.forEach((b) => b.dispose?.()); boxes.clear();
    if (!sel.length) { gizmo.detach(); return false; }
    for (const o of sel) { o.updateMatrixWorld(true); boxes.add(new THREE.BoxHelper(o, 0xf3d189)); }
    base.c.set(0, 0, 0);
    for (const o of sel) base.c.add(new THREE.Vector3(o.userData.u, o.userData.h, o.userData.v));
    base.c.divideScalar(sel.length);
    // one model: the handles turn and size with it; many: from nought
    base.rot = sel.length === 1 ? sel[0].userData.yaw * Math.PI / 180 - Math.PI / 2 : 0;
    base.scale = sel.length === 1 ? sel[0].userData.scale : 1;
    proxy.position.copy(base.c); proxy.rotation.set(0, base.rot, 0); proxy.scale.setScalar(base.scale);
    gizmo.attach(proxy);
    gizmo.showX = gizmo.showZ = gizmo.mode !== 'rotate'; gizmo.showY = true;
    return true;
  }
  function setGizmoMode(m) {
    gizmo.setMode(m);
    gizmo.showX = gizmo.showZ = m !== 'rotate';
    gizmo.showY = true;
    gizmo.enabled = !(m === 'scale' && sel.length && sel.every((o) => o.userData.wmo));
  }
  // the pack's models inside a box on the screen (client pixels)
  function inRect(r0) {
    const r = canvas.getBoundingClientRect(), v = new THREE.Vector3(), out = [];
    for (const o of models.children) {
      const d = o.userData; if (!d?.uid) continue;
      v.set(d.u, d.h + 1, d.v).project(camera);
      if (v.z > 1) continue;
      const x = r.left + (v.x + 1) / 2 * r.width, y = r.top + (1 - v.y) / 2 * r.height;
      if (x >= r0.x0 && x <= r0.x1 && y >= r0.y0 && y <= r0.y1) out.push(d.uid);
    }
    return out;
  }
  // the pack's own model under the pointer
  // the game's own doodad or building under the pointer: { uid, path, u, v } or null
  function pickGame(e) {
    const r = canvas.getBoundingClientRect();
    ndc.set((e.clientX - r.left) / r.width * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    const theirs = models.children.filter((o) => o.userData?.game != null);
    for (const o of theirs) o.updateMatrixWorld(true);
    const hit = ray.intersectObjects(theirs, false)[0];
    return hit ? { uid: hit.object.userData.game, path: hit.object.userData.path } : null;
  }
  function pickMine(e) {
    const r = canvas.getBoundingClientRect();
    ndc.set((e.clientX - r.left) / r.width * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    const mine = models.children.filter((o) => o.userData?.uid);
    for (const o of mine) o.updateMatrixWorld(true);
    const hit = ray.intersectObjects(mine, false)[0];
    return hit ? hit.object.userData.uid : null;
  }

  // ---- Walk: a character on the ground, the camera behind it ---------------------------------
  // WASD move (A/D sidestep), the mouse turns the view, Space jumps, Shift walks, the wheel
  // brings the camera in (all the way: through the character's eyes). Crossing the tile's edge
  // asks the app for the next tile (onEdge), and goes on there.
  const W = { on: false, u: 0, v: 0, y: 0, vy: 0, yaw: 0, look: 0, pitch: 0.3, dist: 9, keys: new Set(), drag: null, body: null, swimming: false, onEdge: null, onMove: null, paused: false, model: 'Character\\Human\\Male\\HumanMale.mdx' };
  const walkerGroup = new THREE.Group(); walkerGroup.visible = false; scene.add(walkerGroup);
  {
    const body = new THREE.Mesh(new THREE.CapsuleGeometry(0.45, 1.1, 4, 10), new THREE.MeshLambertMaterial({ color: 0xe2b65a }));
    body.position.y = 1.0; walkerGroup.add(body); W.body = body;
    const nose = new THREE.Mesh(new THREE.ConeGeometry(0.18, 0.5, 8), new THREE.MeshLambertMaterial({ color: 0x1a1408 }));
    nose.rotation.z = -Math.PI / 2; nose.position.set(0.55, 1.45, 0); walkerGroup.add(nose); W.nose = nose;
  }
  {
    const c = document.createElement('canvas'); c.width = c.height = 64;
    const g = c.getContext('2d'), grd = g.createRadialGradient(32, 32, 2, 32, 32, 32);
    grd.addColorStop(0, 'rgba(0,0,0,0.55)'); grd.addColorStop(1, 'rgba(0,0,0,0)'); g.fillStyle = grd; g.fillRect(0, 0, 64, 64);
    const shadow = new THREE.Mesh(new THREE.PlaneGeometry(1.6, 1.6), new THREE.MeshBasicMaterial({ map: new THREE.CanvasTexture(c), transparent: true, depthWrite: false }));
    shadow.rotation.x = -Math.PI / 2; shadow.renderOrder = 2; scene.add(shadow); W.shadow = shadow; shadow.visible = false;
  }
  let walkerModel = null;
  async function dressWalker() {
    if (walkerModel || !fetchMesh) return;
    const tpl = await meshFor(W.model);
    if (!tpl) return;
    walkerModel = tpl.clone(); walkerModel.matrixAutoUpdate = false;
    // model space: x forward, y left, z up → our x forward, y up, z right
    walkerModel.matrix.set(1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1);
    walkerGroup.add(walkerModel); W.body.visible = false; W.nose.visible = false;
  }
  function placeWalker() {
    walkerGroup.position.set(W.u, W.y, W.v);
    const gh = groundAt(W.u, W.v);
    W.shadow.visible = walkerGroup.visible && !W.swimming;
    W.shadow.position.set(W.u, gh + 0.08, W.v);
    W.shadow.scale.setScalar(Math.max(0.4, 1 - (W.y - gh) * 0.15));
    walkerGroup.rotation.y = -W.yaw;
    const d = W.dist, eye = W.y + 1.75;
    walkerGroup.visible = d > 1.2;
    const cx = Math.cos(W.look), cz = Math.sin(W.look), cp = Math.cos(W.pitch), sp = Math.sin(W.pitch);
    if (d <= 1.2) {
      camera.position.set(W.u, eye, W.v);
      camera.lookAt(W.u + cx * cp * 10, eye - sp * 10, W.v + cz * cp * 10);
    } else {
      let camY = eye + sp * d;
      const camU = W.u - cx * cp * d, camV = W.v - cz * cp * d;
      camY = Math.max(camY, groundAt(camU, camV) + 0.6);
      camera.position.set(camU, camY, camV);
      camera.lookAt(W.u, eye - 0.2, W.v);
    }
  }
  function stepWalker(dt) {
    if (!W.on || W.paused || !heights) return;
    const k = W.keys, run = k.has('shift') ? 2.5 : 7;
    let f = (k.has('w') || k.has('arrowup') ? 1 : 0) - (k.has('s') || k.has('arrowdown') ? 0.5 : 0);
    let sdir = (k.has('d') || k.has('e') ? 1 : 0) - (k.has('a') || k.has('q') ? 1 : 0);
    if (k.has('arrowleft')) W.look -= 2.5 * dt;
    if (k.has('arrowright')) W.look += 2.5 * dt;
    W.moving = !!(f || sdir);
    if (f || sdir) {
      W.yaw = W.look;
      const len = Math.hypot(f, sdir) || 1;
      const sp = run * (f < 0 && !sdir ? 0.5 : 1);
      W.u += (Math.cos(W.yaw) * f - Math.sin(W.yaw) * sdir) / len * sp * dt * (f ? Math.abs(f) : 1);
      W.v += (Math.sin(W.yaw) * f + Math.cos(W.yaw) * sdir) / len * sp * dt * (f ? Math.abs(f) : 1);
    }
    const g = groundAt(W.u, W.v), surf = waterAt(W.u, W.v);
    W.swimming = surf != null && surf - g > 1.6;
    if (W.swimming) {
      W.vy = 0; W.y += ((surf - 1.4) - W.y) * Math.min(1, dt * 6);
    } else {
      W.vy -= 19.3 * dt; W.y += W.vy * dt;
      if (W.y <= g) { W.y = g; W.vy = 0; W.grounded = true; } else W.grounded = W.y - g < 0.05;
    }
    // over the edge: the next tile
    const da = W.u < 0 ? -1 : W.u >= size ? 1 : 0, db = W.v < 0 ? -1 : W.v >= size ? 1 : 0;
    if ((da || db) && W.onEdge) {
      W.paused = true;
      W.onEdge({ da, db, u: W.u - da * size, v: W.v - db * size, y: W.y, yaw: W.yaw, look: W.look });
    } else {
      W.u = Math.max(0.01, Math.min(size - 0.01, W.u)); W.v = Math.max(0.01, Math.min(size - 0.01, W.v));
    }
    W.onMove?.({ u: W.u, v: W.v, y: W.y, swimming: W.swimming });
  }
  const keyName = (e) => e.key.toLowerCase();
  window.addEventListener('keydown', (e) => {
    if (!W.on || typing()) return;
    const n = keyName(e);
    if (n === ' ' && W.grounded && !W.swimming) { W.vy = 7.9; W.grounded = false; }
    if (n === ' ' && W.swimming) W.y += 0.6;
    if ([' ', 'arrowup', 'arrowdown', 'arrowleft', 'arrowright'].includes(n)) e.preventDefault();
    W.keys.add(n);
  });
  window.addEventListener('keyup', (e) => W.keys.delete(keyName(e)));
  window.addEventListener('blur', () => W.keys.clear());
  canvas.addEventListener('pointerdown', (e) => { if (!W.on) return; W.drag = { x: e.clientX, y: e.clientY }; canvas.setPointerCapture(e.pointerId); e.preventDefault(); e.stopImmediatePropagation(); }, true);
  canvas.addEventListener('pointermove', (e) => {
    if (!W.on || !W.drag) return;
    W.look += (e.clientX - W.drag.x) * 0.006; W.pitch = Math.max(-1.2, Math.min(1.35, W.pitch + (e.clientY - W.drag.y) * 0.005));
    W.drag = { x: e.clientX, y: e.clientY };
  }, true);
  canvas.addEventListener('pointerup', () => { W.drag = null; }, true);
  canvas.addEventListener('wheel', (e) => { if (!W.on) return; e.preventDefault(); e.stopImmediatePropagation(); W.dist = Math.max(0, Math.min(40, W.dist * (e.deltaY > 0 ? 1.15 : 0.87) + (e.deltaY > 0 ? 0.3 : -0.3))); }, { capture: true, passive: false });
  // walking: the clean ground (the app's sharper picture of it, without the map's marks)
  let walkTex = null;
  function setWalkGround(img) {
    walkTex?.dispose(); walkTex = null;
    if (img) { walkTex = new THREE.Texture(img); walkTex.colorSpace = THREE.SRGBColorSpace; walkTex.anisotropy = renderer.capabilities.getMaxAnisotropy(); walkTex.needsUpdate = true; }
    groundMaterial();
  }
  // the ground as the game paints it, on the graphics card: each chunk's layers (up to four
  // textures, each repeating 8 times across the chunk) blended by its 64 × 64 alpha maps
  let splatMat = null;
  const pixels = (img) => { const c = document.createElement('canvas'); c.width = img.width; c.height = img.height; const g = c.getContext('2d'); g.drawImage(img, 0, 0); return new Uint8Array(g.getImageData(0, 0, img.width, img.height).data.buffer); };
  const dropSplat = (m) => { if (m) { for (const k of ['tex', 'idx', 'alpha', 'shade']) m.uniforms[k].value?.dispose(); m.dispose(); } };
  function setSplat(sp) {
    dropSplat(splatMat); splatMat = null;
    if (sp) splatMat = makeSplat(sp);
    groundMaterial();
  }
  function makeSplat(sp) {
    {
      const n = sp.textures.length || 1, z = sp.size;
      const arr = new THREE.DataArrayTexture(pixels(sp.atlas), z, z, n);
      arr.format = THREE.RGBAFormat; arr.wrapS = arr.wrapT = THREE.RepeatWrapping;
      arr.minFilter = THREE.LinearMipmapLinearFilter; arr.magFilter = THREE.LinearFilter; arr.generateMipmaps = true;
      arr.anisotropy = renderer.capabilities.getMaxAnisotropy(); arr.needsUpdate = true;
      const idx = new THREE.DataTexture(pixels(sp.index), 32, 16); idx.minFilter = idx.magFilter = THREE.NearestFilter; idx.needsUpdate = true;
      const al = new THREE.DataTexture(pixels(sp.alpha), 1024, 1024); al.minFilter = al.magFilter = THREE.LinearFilter; al.needsUpdate = true;
      // the game's baked shadows (soft at their edges, as the game draws them)
      const sh = sp.shadow ? new THREE.DataTexture(pixels(sp.shadow), 1024, 1024) : new THREE.DataTexture(new Uint8Array(4), 1, 1);
      sh.minFilter = sh.magFilter = THREE.LinearFilter; sh.needsUpdate = true;
      return new THREE.ShaderMaterial({
        glslVersion: THREE.GLSL3,
        uniforms: { tex: { value: arr }, idx: { value: idx }, alpha: { value: al }, shade: { value: sh }, size: { value: size }, sun: { value: new THREE.Vector3(-0.45, 0.75, -0.45) },
          fogColor: fogSRGB, ambient: ambU, sunCol: sunU, fogNear: fogNearU, fogFar: fogFarU, slope: { value: overlays.slope ? 1 : 0 } },
        vertexShader: `uniform float size; out vec2 vTile; out vec3 vN; out float vDepth;
          void main() { vTile = position.xz / size; vN = normal; vec4 mv = modelViewMatrix * vec4(position, 1.0); vDepth = -mv.z; gl_Position = projectionMatrix * mv; }`,
        fragmentShader: `precision highp float; precision highp sampler2DArray;
          uniform sampler2DArray tex; uniform sampler2D idx; uniform sampler2D alpha; uniform sampler2D shade; uniform vec3 sun; uniform vec3 fogColor; uniform vec3 ambient; uniform vec3 sunCol; uniform float fogNear; uniform float fogFar; uniform float slope;
          in vec2 vTile; in vec3 vN; in float vDepth; out vec4 outColor;
          vec3 layer(float i, vec2 uv) { return texture(tex, vec3(uv, i - 1.0)).rgb; }
          void main() {
            vec2 c = clamp(vTile, 0.0, 0.99999) * 16.0; vec2 ch = floor(c);
            vec3 i3 = floor(texelFetch(idx, ivec2(int(ch.x) * 2, int(ch.y)), 0).rgb * 255.0 + 0.5);
            vec4 ids = vec4(i3, floor(texelFetch(idx, ivec2(int(ch.x) * 2 + 1, int(ch.y)), 0).r * 255.0 + 0.5));
            // a chunk's alpha map, sampled inside the chunk (its neighbours' never bleed in)
            vec2 a = (ch * 64.0 + clamp(fract(c) * 64.0, 0.5, 63.5)) / 1024.0;
            vec3 al = texture(alpha, a).rgb;
            vec2 uv = c * 8.0;
            vec3 col = ids.x > 0.5 ? layer(ids.x, uv) : vec3(0.43, 0.47, 0.31);
            if (ids.y > 0.5) col = mix(col, layer(ids.y, uv), al.r);
            if (ids.z > 0.5) col = mix(col, layer(ids.z, uv), al.g);
            if (ids.w > 0.5) col = mix(col, layer(ids.w, uv), al.b);
            // baked shadow takes the sun away there (a little of it: the game's shadows are soft)
            float sh = texture(shade, clamp(vTile, 0.0, 1.0)).r;
            col *= ambient * (1.0 - 0.25 * sh) + sunCol * max(dot(normalize(vN), normalize(sun)), 0.0) * (1.0 - 0.75 * sh);
            // the slope overlay: red where it's too steep to walk up (about 50°)
            if (slope > 0.5) { float st = smoothstep(0.66, 0.6, normalize(vN).y); col = mix(col, vec3(0.85, 0.15, 0.1), st * 0.55); }
            outColor = vec4(mix(col, fogColor, smoothstep(fogNear, fogFar, vDepth)), 1.0);
          }`,
      });
    }
  }

  // the tiles around: ground, water and models (instanced: many trees, few draw calls), shown
  // where they lie next to the one being edited; read-only
  const nbs = new Map();
  const nbRoot = new THREE.Group(); scene.add(nbRoot);
  function dropNb(n) {
    nbRoot.remove(n.group);
    n.group.traverse((o) => { if (o.isInstancedMesh) o.dispose(); });
    n.ground.geometry.dispose(); n.water?.geometry.dispose(); dropSplat(n.mat);
  }
  async function nbModels(n, t) {
    const by = new Map();
    const add = (path, u, h, v, yaw, sc, tilt) => { if (!path) return; const k = path.toLowerCase(); if (!by.has(k)) by.set(k, { path, list: [] }); by.get(k).list.push([u, h, v, yaw, sc, tilt]); };
    for (const d of t.stock) if (!d.hidden) add(d.path, d.u, d.h, d.v, d.rot?.[1] || 0, d.scale || 1, [d.rot?.[0] || 0, d.rot?.[2] || 0]);
    for (const w of t.buildings || []) if (!w.hidden) add(w.path, w.u, w.h, w.v, w.rot?.[1] || 0, 1);
    for (const m of t.mine) add(m.path, m.u, m.h, m.v, m.placement?.turn || 0, m.placement?.scale || 1, m.placement?.tilt);
    for (const { path, list } of by.values()) {
      const tpl = await meshFor(path);
      if (!tpl || !nbs.has(n.key) || !modelsOn) continue;
      const im = new THREE.InstancedMesh(tpl.geometry, tpl.material, list.length);
      const m4 = new THREE.Matrix4();
      list.forEach(([u, h, v, yaw, sc, tilt], i) => {
        objMatrix(m4, u, h, v, yaw, sc, tilt);
        im.setMatrixAt(i, m4);
      });
      im.instanceMatrix.needsUpdate = true; im.computeBoundingSphere();
      n.models.add(im);
    }
  }
  // list: [{key, a, b, tile, splat}]; centre: {a, b}
  function setNeighbours(list, centre) {
    const want = new Set(list.map((x) => x.key));
    for (const [k, n] of nbs) if (!want.has(k)) { dropNb(n); nbs.delete(k); }
    for (const x of list) {
      let n = nbs.get(x.key);
      if (!n) {
        const group = new THREE.Group();
        const mat = x.splat ? makeSplat(x.splat) : new THREE.MeshLambertMaterial({ color: 0x6b6a4a });
        const ground = new THREE.Mesh(buildGround(x.tile), mat);
        group.add(ground);
        const water = buildWater(x.tile); if (water) group.add(water);
        const models = new THREE.Group(); group.add(models);
        n = { key: x.key, a: x.a, b: x.b, group, ground, water, models, mat: x.splat ? mat : null, tile: x.tile };
        nbs.set(x.key, n); nbRoot.add(group);
        nbModels(n, x.tile);
      }
      n.group.position.set((x.a - centre.a) * size, 0, (x.b - centre.b) * size);
      if (n.mat) n.mat.uniforms.slope.value = overlays.slope ? 1 : 0;
    }
  }
  // ---- far off: the ring of tiles past the neighbours, low and simple (33 × 33 heights, the ground's
  // colours, flat water per chunk), with skirts so no sky shows between them and the near tiles
  const farRoot = new THREE.Group(); scene.add(farRoot);
  // the view's settings (Forge saves them): how far you see, what moves, how much detail
  const VS = { distance: 1700, far: true, neighbours: true, particles: true, animate: true, detail: 260 };
  let cullAt = 0;
  const fars = new Map();
  const farWater = new THREE.MeshLambertMaterial({ color: 0x3f6f8f, transparent: true, opacity: 0.8, depthWrite: false });
  function buildFar(f) {
    const M = 35, pos = new Float32Array(M * M * 3), uv = new Float32Array(M * M * 2);
    for (let i = 0; i < M; i++) for (let j = 0; j < M; j++) {
      const ii = Math.min(32, Math.max(0, i - 1)), jj = Math.min(32, Math.max(0, j - 1)), skirt = i === 0 || j === 0 || i === M - 1 || j === M - 1, k = i * M + j;
      pos[k * 3] = jj / 32 * size; pos[k * 3 + 1] = f.heights[ii * 33 + jj] - (skirt ? 25 : 0); pos[k * 3 + 2] = ii / 32 * size;
      uv[k * 2] = jj / 32; uv[k * 2 + 1] = 1 - ii / 32;
    }
    const idx = [];
    for (let i = 0; i < M - 1; i++) for (let j = 0; j < M - 1; j++) { const k = i * M + j; idx.push(k, k + M, k + 1, k + 1, k + M, k + M + 1); }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3)); g.setAttribute('uv', new THREE.BufferAttribute(uv, 2));
    g.setIndex(idx); g.computeVertexNormals();
    const tex = new THREE.Texture(f.image); tex.colorSpace = THREE.SRGBColorSpace; tex.needsUpdate = true; tex.anisotropy = 4;
    const group = new THREE.Group();
    group.add(new THREE.Mesh(g, new THREE.MeshLambertMaterial({ map: tex, side: THREE.DoubleSide })));
    const wp = [], cs = size / 16;
    f.water.forEach((h, k) => { if (h == null) return; const x0 = (k % 16) * cs, z0 = Math.floor(k / 16) * cs; wp.push(x0, h, z0, x0, h, z0 + cs, x0 + cs, h, z0, x0 + cs, h, z0, x0, h, z0 + cs, x0 + cs, h, z0 + cs); });
    if (wp.length) { const wg = new THREE.BufferGeometry(); wg.setAttribute('position', new THREE.Float32BufferAttribute(wp, 3)); wg.computeVertexNormals(); group.add(new THREE.Mesh(wg, farWater)); }
    return group;
  }
  function setFar(list, centre) {
    const want = new Set(list.map((x) => x.key));
    for (const [k, n] of fars) if (!want.has(k)) { n.traverse((o) => { o.geometry?.dispose(); if (o.material && o.material !== farWater) { o.material.map?.dispose(); o.material.dispose(); } }); farRoot.remove(n); fars.delete(k); }
    for (const x of list) {
      let n = fars.get(x.key);
      if (!n) { n = buildFar(x.far); fars.set(x.key, n); farRoot.add(n); }
      n.position.set((x.a - centre.a) * size, 0, (x.b - centre.b) * size);
    }
  }

  let plainMat = null, splatOn = false;
  function groundMaterial() {
    if (!ground) return;
    if ((W.on || splatOn) && splatMat) { splatMat.uniforms.size.value = size; ground.material = splatMat; return; }
    if (!plainMat) plainMat = ground.material;
    ground.material = plainMat;
    plainMat.map = W.on && walkTex ? walkTex : tex; plainMat.needsUpdate = true;
  }
  // overlays: chunk and tile lines (F7), the slope (Shift+F2)
  const overlays = { lines: false, slope: false };
  let lines = null;
  function buildLines() {
    if (lines) { scene.remove(lines); lines.geometry.dispose(); lines = null; }
    if (!heights) return;
    const pts = [], cols = [];
    const add = (u0, v0, u1, v1, edge) => {
      const n = 32;
      for (let i = 0; i < n; i++) {
        const a = i / n, b = (i + 1) / n;
        const ua = u0 + (u1 - u0) * a, va = v0 + (v1 - v0) * a, ub = u0 + (u1 - u0) * b, vb = v0 + (v1 - v0) * b;
        pts.push(ua, groundAt(ua, va) + 0.25, va, ub, groundAt(ub, vb) + 0.25, vb);
        const c = edge ? [0.35, 0.95, 0.4] : [0.95, 0.3, 0.25];
        cols.push(...c, ...c);
      }
    };
    for (let k = 0; k <= 16; k++) { const p = k / 16 * size, edge = k === 0 || k === 16; add(p, 0, p, size, edge); add(0, p, size, p, edge); }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pts, 3));
    g.setAttribute('color', new THREE.Float32BufferAttribute(cols, 3));
    lines = new THREE.LineSegments(g, new THREE.LineBasicMaterial({ vertexColors: true, transparent: true, opacity: 0.75 }));
    lines.visible = overlays.lines; scene.add(lines);
  }
  function setOverlay(k, on) {
    overlays[k] = on;
    if (k === 'lines') { if (on && !lines) buildLines(); if (lines) lines.visible = on; }
    if (k === 'slope') { if (splatMat) splatMat.uniforms.slope.value = on ? 1 : 0; for (const n of nbs.values()) if (n.mat) n.mat.uniforms.slope.value = on ? 1 : 0; }
  }
  // flying: WASD (QE down/up, Shift faster) moves the camera and what it looks at together
  const fly = new Set();
  const typing = () => { const a = document.activeElement; return !!a && (a.tagName === 'TEXTAREA' || a.tagName === 'SELECT' || (a.tagName === 'INPUT' && !['checkbox', 'radio', 'range', 'button'].includes(a.type))); };
  window.addEventListener('keydown', (e) => {
    if (W.on || typing() || e.ctrlKey || e.metaKey || e.altKey || !canvas.offsetParent) return;
    const k = e.key.toLowerCase();
    if (['w', 'a', 's', 'd', 'q', 'e', 'shift'].includes(k)) fly.add(k);
  });
  window.addEventListener('keyup', (e) => fly.delete(e.key.toLowerCase()));
  window.addEventListener('blur', () => fly.clear());
  function stepFly(dt) {
    if (!fly.size || W.on) return;
    const fwd = new THREE.Vector3(); camera.getWorldDirection(fwd); fwd.y = 0; fwd.normalize();
    const right = new THREE.Vector3(-fwd.z, 0, fwd.x);
    const dist = camera.position.distanceTo(controls.target);
    const speed = Math.max(25, dist * 0.9) * (fly.has('shift') ? 3 : 1) * dt;
    const m = new THREE.Vector3();
    if (fly.has('w')) m.add(fwd); if (fly.has('s')) m.sub(fwd);
    if (fly.has('d')) m.add(right); if (fly.has('a')) m.sub(right);
    if (m.lengthSq()) m.normalize().multiplyScalar(speed);
    if (fly.has('e')) m.y += speed; if (fly.has('q')) m.y -= speed;
    camera.position.add(m); controls.target.add(m);
  }

  // the brush, as a ring lying on the ground (the painted look has no map to draw it on)
  const ringGeo = new THREE.BufferGeometry(); ringGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(97 * 3), 3));
  const ring = new THREE.Line(ringGeo, new THREE.LineBasicMaterial({ color: 0xf3d189, depthTest: false, transparent: true, opacity: 0.95 }));
  ring.renderOrder = 10; ring.visible = false; ring.frustumCulled = false; scene.add(ring);
  const dot = new THREE.Mesh(new THREE.SphereGeometry(0.6, 10, 8), new THREE.MeshBasicMaterial({ color: 0xf3d189, depthTest: false }));
  dot.renderOrder = 10; dot.visible = false; scene.add(dot);
  const ring2Geo = new THREE.BufferGeometry(); ring2Geo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(97 * 3), 3));
  const ring2 = new THREE.Line(ring2Geo, new THREE.LineDashedMaterial({ color: 0xf3d189, dashSize: 1.2, gapSize: 0.8, depthTest: false, transparent: true, opacity: 0.7 }));
  ring2.renderOrder = 10; ring2.visible = false; ring2.frustumCulled = false; scene.add(ring2);
  function setBrush(b) {
    ring.visible = dot.visible = !!b && !W.on;
    ring2.visible = !!b && !W.on && (b.inner || 0) > 0.02;
    if (ring2.visible) {
      const a2 = ring2Geo.attributes.position, r2 = b.r * b.inner;
      for (let i = 0; i <= 96; i++) { const t = i / 96 * Math.PI * 2, u = b.u + Math.cos(t) * r2, v = b.v + Math.sin(t) * r2; a2.setXYZ(i, u, groundAt(u, v) + 0.4, v); }
      a2.needsUpdate = true; ring2.computeLineDistances();
    }
    if (!b) return;
    const a = ringGeo.attributes.position;
    for (let i = 0; i <= 96; i++) {
      const t = i / 96 * Math.PI * 2, u = b.u + Math.cos(t) * b.r, v = b.v + Math.sin(t) * b.r;
      a.setXYZ(i, u, groundAt(u, v) + 0.4, v);
    }
    a.needsUpdate = true;
    ring.material.color.set(b.color || 0xf3d189);
    dot.position.set(b.u, groundAt(b.u, b.v) + 0.4, b.v);
  }
  function walk(on, at) {
    W.on = on; W.keys.clear();
    controls.enabled = !on;
    if (pins) pins.visible = !on;
    groundMaterial();
    if (on) {
      if (at) { W.u = at.u; W.v = at.v; }
      else if (W.u <= 0 || W.u >= size) { W.u = controls.target.x; W.v = controls.target.z; }
      W.y = groundAt(W.u, W.v) + 0.5; W.vy = 0; W.paused = false;
      walkerGroup.visible = true; dressWalker();
    } else {
      walkerGroup.visible = false; W.shadow.visible = false;
      controls.target.set(W.u, W.y + 1, W.v);
      camera.position.set(W.u - Math.cos(W.look) * 60, W.y + 45, W.v - Math.sin(W.look) * 60);
    }
  }

  // t: the tile view; map: the 2D canvas, drawn already (draped as the texture)
  function update(t, map) {
    size = t.size; heights = t.heights;
    if (ground) { scene.remove(ground); ground.geometry.dispose(); }
    if (!tex || tex.image !== map) { tex?.dispose(); tex = new THREE.CanvasTexture(map); tex.colorSpace = THREE.SRGBColorSpace; tex.anisotropy = 4; }
    tex.needsUpdate = true;
    plainMat?.dispose(); plainMat = new THREE.MeshLambertMaterial({ map: tex });
    ground = new THREE.Mesh(buildGround(t), plainMat);
    groundMaterial();
    scene.add(ground);
    if (water) { scene.remove(water); water.geometry.dispose(); }
    water = buildWater(t); if (water) scene.add(water);
    if (pins) scene.remove(pins);
    pins = buildPins(t); pins.visible = !W.on; scene.add(pins);
    modelsFor = null; showModels(t);
    if (overlays.lines) buildLines(); else if (lines) { scene.remove(lines); lines.geometry.dispose(); lines = null; }
    if (!framed) {
      let lo = Infinity, hi = -Infinity; for (const h of t.heights) { lo = Math.min(lo, h); hi = Math.max(hi, h); }
      controls.target.set(size / 2, (lo + hi) / 2, size / 2);
      camera.position.set(size / 2, hi + size * 0.55, size * 1.25);
      framed = true;
    }
  }
  // only the drape changed (brush ring, overlays)
  function redrape() { if (tex) tex.needsUpdate = true; }

  // the ground under the pointer: tile-local (u, v) and the height
  function pick(e) {
    if (!ground) return null;
    const r = canvas.getBoundingClientRect();
    ndc.set((e.clientX - r.left) / r.width * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    const hit = ray.intersectObject(ground, false)[0];
    return hit ? { u: hit.point.x, v: hit.point.z, h: hit.point.y } : null;
  }

  let running = true;
  const stats = { fps: 0, frames: 0, since: performance.now(), last: 0, tris: 0 };
  function loop() {
    if (!running) return;
    requestAnimationFrame(loop);
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (w && h && (canvas.width !== Math.floor(w * renderer.getPixelRatio()) || canvas.height !== Math.floor(h * renderer.getPixelRatio()))) {
      renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix();
    }
    const now = performance.now(), dt = Math.min(0.1, (now - (stats.last || now)) / 1000);
    stats.last = now; stats.frames++; waterTime.value = now / 1000;
    if (animated.size && VS.animate) animate(now);
    if (systems.size && VS.particles) stepParticles(dt);
    farRoot.visible = VS.far; nbRoot.visible = VS.neighbours;
    // small props far off: hidden (a few each frame, so it never stalls)
    if (models.children.length) {
      const list = models.children, n = Math.min(list.length, 60);
      for (let k = 0; k < n; k++) {
        const o = list[(cullAt + k) % list.length];
        if (o.userData.uid || !o.geometry) continue;
        if (!o.geometry.boundingSphere) o.geometry.computeBoundingSphere();
        const r = (o.geometry.boundingSphere?.radius || 1) * Math.hypot(o.matrix.elements[0], o.matrix.elements[1], o.matrix.elements[2]);
        _v.setFromMatrixPosition(o.matrix);
        o.visible = r > 12 || _v.distanceTo(camera.position) < VS.detail * (0.5 + r / 6);
      }
      cullAt = (cullAt + n) % Math.max(1, list.length);
    }
    if (now - stats.since > 1000) { stats.fps = Math.round(stats.frames * 1000 / (now - stats.since)); stats.frames = 0; stats.since = now; }
    if (W.on) { stepWalker(dt); placeWalker(); } else { stepFly(dt); controls.update(); }
    scene.userData.sky.position.copy(camera.position);
    {
      const focus = W.on ? 0 : camera.position.distanceTo(controls.target);
      fogNearU.value = scene.fog.near = focus + VS.distance * 0.32; fogFarU.value = scene.fog.far = focus + VS.distance;
      camera.far = focus + VS.distance + 400;
    }
    camera.updateProjectionMatrix();
    renderer.render(scene, camera);
    stats.tris = renderer.info.render.triangles;
  }
  loop();
  canvas.addEventListener('contextmenu', (e) => e.preventDefault());
  let lastTile = null;
  const update0 = update;
  return {
    update(t, map) { lastTile = t; update0(t, map); }, redrape, pick, reframe() { framed = false; },
    // True View models: on/off, and how to fetch a mesh (path → mesh JSON) and a texture (path → data URL)
    // Walk: on/off (at tile-local {u, v}); go on at a new tile after onEdge; status for the bar
    // look at a spot from above and to the south, near enough to work
    focus(u, v) { const h = groundAt(u, v); controls.target.set(u, h, v); camera.position.set(u, h + 90, v + 120); },
    viewSettings: () => ({ ...VS }),
    setViewSettings(v) { Object.assign(VS, v || {}); if (!VS.particles) for (const S of systems) S.g.setDrawRange(0, 0); for (const o of models.children) o.visible = true; },
    getView() { return { target: controls.target.toArray(), eye: camera.position.toArray() }; },
    setView(vw) { if (!vw?.target) return; controls.target.fromArray(vw.target); camera.position.fromArray(vw.eye); controls.update(); },
    // selection: pick one of the pack's models, show handles, report where it's let go
    pickMine, pickGame, select, setsFor: async (path) => setsOf.get((await meshFor(path))?.geometry) || [], setGizmoMode, inRect, onGizmo(cb) { onGizmo = cb; }, onProgress(cb) { onProgress = cb; },
    gizmoHover: () => gizmo.axis !== null,
    gizmoDragged() { const b = dragged; dragged = false; return b; },
    setSky, setLights,
    walk, isWalking: () => W.on, setWalkGround, setSplat, setBrush, setOverlay, overlays: () => ({ ...overlays }), setNeighbours, setFar,
    // the ground painted by its textures while editing too (else the 2D map draped on it)
    setSplatMode(on) { splatOn = on; groundMaterial(); }, hasSplat: () => !!splatMat,
    walkResume(at) { W.u = at.u; W.v = at.v; W.y = Math.max(at.y ?? 0, groundAt(at.u, at.v)); if (at.look != null) W.look = at.look; W.yaw = at.yaw ?? W.yaw; W.paused = false; },
    onWalk(edge, move) { W.onEdge = edge; W.onMove = move; },
    walker: () => ({ u: W.u, v: W.v, y: W.y, yaw: W.yaw, swimming: W.swimming }),
    stats: () => ({ fps: stats.fps, tris: stats.tris, particles: systems.size }),
    setModels(on, mesh, tex) {
      modelsOn = on; if (mesh) fetchMesh = mesh; if (tex) fetchTexture = tex; if (pins) artPins(on); if (lastTile) { modelsFor = undefined; showModels(lastTile); }
      // the tiles around too
      for (const n of nbs.values()) { n.models.visible = on; if (on && !n.models.children.length && n.tile) nbModels(n, n.tile); }
    },
    dispose() { running = false; renderer.dispose(); },
  };
}

window.forgeTerrain = { createTerrain };
window.dispatchEvent(new Event('forge-terrain-ready'));
