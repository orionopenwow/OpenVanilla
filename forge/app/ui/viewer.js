// The Models screen's 3D view: the ported 1.12 model as the game reads it back (the Model
// Porter's viewer JSON: mesh, skeleton, every animation), with a sliding ground for walk/run
// clips and the seat and attachment points. Adapted from tools/modelport/ui.html.
import * as THREE from './vendor/three.module.min.js';
import { OrbitControls } from './vendor/OrbitControls.js';

export function createViewer(canvas, chips) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, preserveDrawingBuffer: true });
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(40, 1, 0.05, 500);
  const controls = new OrbitControls(camera, canvas);
  controls.enableDamping = true;
  scene.add(new THREE.HemisphereLight(0xd8d0c0, 0x2a2016, 1.25));
  const sun = new THREE.DirectionalLight(0xfff1d8, 2.0); sun.position.set(4, 8, 5); scene.add(sun);
  const rim = new THREE.DirectionalLight(0x8fb0ff, 0.8); rim.position.set(-6, 3, -4); scene.add(rim);

  const gcan = document.createElement('canvas'); gcan.width = gcan.height = 128;
  const gx = gcan.getContext('2d');
  gx.fillStyle = '#1a1712'; gx.fillRect(0, 0, 128, 128);
  gx.strokeStyle = 'rgba(226,182,90,.35)'; gx.lineWidth = 2; gx.strokeRect(0, 0, 128, 128);
  gx.strokeStyle = 'rgba(226,182,90,.12)'; gx.lineWidth = 1; gx.beginPath(); gx.moveTo(64, 0); gx.lineTo(64, 128); gx.moveTo(0, 64); gx.lineTo(128, 64); gx.stroke();
  const gtex = new THREE.CanvasTexture(gcan); gtex.wrapS = gtex.wrapT = THREE.RepeatWrapping; gtex.colorSpace = THREE.SRGBColorSpace;
  const GROUND = 40; gtex.repeat.set(GROUND / 2, GROUND / 2);
  const ground = new THREE.Mesh(new THREE.CircleGeometry(GROUND / 2, 64), new THREE.MeshLambertMaterial({ map: gtex, transparent: true, opacity: 0.95 }));
  ground.rotation.x = -Math.PI / 2; scene.add(ground);

  let model = null, mixer = null, actions = [], active = null, markers = [];
  const clock = new THREE.Clock();
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  function show(p, textures, kind) {
    if (model) { scene.remove(model); model.traverse((o) => o.geometry?.dispose?.()); }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.Float32BufferAttribute(p.pos, 3));
    geo.setAttribute('normal', new THREE.Float32BufferAttribute(p.normal, 3));
    geo.setAttribute('uv', new THREE.Float32BufferAttribute(p.uv, 2));
    geo.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(p.joints, 4));
    geo.setAttribute('skinWeight', new THREE.Float32BufferAttribute(p.weights.map((w) => w / 255), 4));
    geo.setIndex(p.index);
    const loader = new THREE.TextureLoader();
    const texs = textures.map((url) => {
      if (!url) return null;
      const tx = loader.load(url); tx.flipY = false; tx.colorSpace = THREE.SRGBColorSpace; tx.anisotropy = 8; return tx;
    });
    const mats = p.batches.map((b, i) => {
      geo.addGroup(b.start, b.count, i);
      const [flags, blend] = b.material;
      return new THREE.MeshLambertMaterial({ map: texs[b.texture] || null, color: texs[b.texture] ? 0xffffff : 0x9a8f80,
        side: flags & 4 ? THREE.DoubleSide : THREE.FrontSide, alphaTest: blend === 1 ? 0.5 : 0, transparent: blend >= 2 });
    });
    const bones = p.bones.map((b, i) => { const bone = new THREE.Bone(); bone.name = 'b' + i; return bone; });
    const roots = [];
    p.bones.forEach((b, i) => {
      const par = b.parent >= 0 ? p.bones[b.parent].pivot : [0, 0, 0];
      bones[i].position.set(b.pivot[0] - par[0], b.pivot[1] - par[1], b.pivot[2] - par[2]);
      bones[i].userData.rest = bones[i].position.clone();
      if (b.parent >= 0) bones[b.parent].add(bones[i]); else roots.push(bones[i]);
    });
    const inv = p.bones.map((b) => new THREE.Matrix4().makeTranslation(-b.pivot[0], -b.pivot[1], -b.pivot[2]));
    const mesh = new THREE.SkinnedMesh(geo, mats);
    roots.forEach((r) => mesh.add(r));
    mesh.bind(new THREE.Skeleton(bones, inv), new THREE.Matrix4());
    mesh.frustumCulled = false;
    model = new THREE.Group(); model.rotation.x = -Math.PI / 2; // WoW is Z-up, facing +X
    model.add(mesh); scene.add(model);

    markers = [];
    for (const a of p.attachments || []) {
      const host = bones[a.bone] || bones[0];
      const piv = p.bones[a.bone]?.pivot || [0, 0, 0];
      const mk = new THREE.Mesh(new THREE.SphereGeometry(0.06, 12, 8), new THREE.MeshBasicMaterial({ color: a.id === 0 ? 0x8fcf7a : 0x8ab4e8, depthTest: false }));
      mk.renderOrder = 10; mk.position.set(a.pos[0] - piv[0], a.pos[1] - piv[1], a.pos[2] - piv[2]); host.add(mk); markers.push(mk);
    }

    mixer = new THREE.AnimationMixer(mesh); actions = []; active = null;
    p.anims.forEach((a) => {
      const byBone = new Map(a.tracks.map((t) => [t.bone, t]));
      const tracks = [];
      p.bones.forEach((b, i) => {
        const t = byBone.get(i), rest = bones[i].userData.rest;
        const pos = t && t.t.length ? t.t : [[0, 0, 0, 0]];
        tracks.push(new THREE.VectorKeyframeTrack(`b${i}.position`, pos.map((k) => k[0]), pos.flatMap((k) => [rest.x + k[1], rest.y + k[2], rest.z + k[3]])));
        const rot = t && t.r.length ? t.r : [[0, 0, 0, 0, 1]];
        tracks.push(new THREE.QuaternionKeyframeTrack(`b${i}.quaternion`, rot.map((k) => k[0]), rot.flatMap((k) => k.slice(1))));
        const sc = t && t.s.length ? t.s : [[0, 1, 1, 1]];
        tracks.push(new THREE.VectorKeyframeTrack(`b${i}.scale`, sc.map((k) => k[0]), sc.flatMap((k) => k.slice(1))));
      });
      const name = `${(p.anim_names || {})[a.id] || 'Anim ' + a.id}${a.var ? ' ' + (a.var + 1) : ''}`;
      const act = mixer.clipAction(new THREE.AnimationClip(name, Math.max(a.dur, 0.001), tracks));
      act.setLoop(a.loop ? THREE.LoopRepeat : THREE.LoopOnce, Infinity); act.clampWhenFinished = true;
      actions.push({ act, a, name });
    });
    if (chips) {
      chips.innerHTML = actions.map((x, i) => `<button class="chip" data-i="${i}">${esc(x.name)}<small>${x.a.dur.toFixed(1)}s${x.a.speed ? ' · ' + x.a.speed.toFixed(1) + ' yd/s' : ''}</small></button>`).join('');
      chips.querySelectorAll('.chip').forEach((c) => c.addEventListener('click', () => play(+c.dataset.i)));
    }
    const prefer = actions.findIndex((x) => x.a.id === (kind === 'mount' ? 5 : 0));
    play(prefer >= 0 ? prefer : 0);
    frame();
  }

  function play(i) {
    if (!actions[i]) return;
    if (active) active.act.fadeOut(0.15);
    active = actions[i];
    active.act.reset().fadeIn(0.15).play();
    chips?.querySelectorAll('.chip').forEach((c, k) => c.classList.toggle('on', k === i));
  }

  function frame() {
    model.updateMatrixWorld(true);
    const geo = model.children[0].geometry; geo.computeBoundingBox();
    const b = geo.boundingBox.clone().applyMatrix4(model.matrixWorld);
    const size = b.getSize(new THREE.Vector3()), center = b.getCenter(new THREE.Vector3());
    const r = Math.max(size.x, size.y, size.z) * 0.5 + 0.6;
    controls.target.copy(center);
    camera.position.copy(center).add(new THREE.Vector3(r * 1.25, r * 0.7, r * 2.3));
    camera.near = r / 100; camera.far = r * 60; camera.updateProjectionMatrix();
  }

  const DIR = { 13: [-1, 0], 45: [-1, 0], 11: [0, 1], 12: [0, -1] };
  let running = true;
  function loop() {
    if (!running) return;
    requestAnimationFrame(loop);
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (w && h && (canvas.width !== Math.floor(w * renderer.getPixelRatio()) || canvas.height !== Math.floor(h * renderer.getPixelRatio()))) {
      renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix();
    }
    const dt = Math.min(0.05, clock.getDelta());
    if (mixer) mixer.update(dt);
    if (active && active.a.speed > 0 && active.a.loop) {
      const [fx, fz] = DIR[active.a.id] || [1, 0];
      gtex.offset.x += fx * active.a.speed * dt / 2;
      gtex.offset.y += fz * active.a.speed * dt / 2;
    }
    controls.update();
    renderer.render(scene, camera);
  }
  loop();
  return { show, play, markers: (on) => markers.forEach((m) => { m.visible = on; }), dispose() { running = false; renderer.dispose(); } };
}

window.forgeViewer = { createViewer };
window.dispatchEvent(new Event('forge-viewer-ready'));
