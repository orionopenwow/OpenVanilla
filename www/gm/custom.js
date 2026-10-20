// custom.js: your room to build on the Open Vanilla GM panel.
// Loaded once after the panel starts. Edit, save, then refresh the game page (F5) to see changes.
// `gm` is the panel API (also `window.gm` in the browser console, F12). Uncomment to try:

export default function (gm) {
  // A button on the bar under the title:
  // gm.addQuick('Dalaran party', '.tele stormwind');

  // More buttons on the Tools tab (a new group, or added to an existing one). A tool with
  // `fields` asks for them in a popup; {key} in cmd is replaced by what you typed:
  // gm.addTools('My server', [
  //   { icon: '🎂', label: 'Birthday kit', tip: 'Cake and fireworks', cmd: ['.additem 21254 5', '.additem 9312 10'] },
  //   { icon: '🐉', label: 'Spawn boss', tip: 'Spawn a creature by ID', fields: [{ key: 'id', label: 'Creature ID', value: '11502' }], cmd: '.npc add {id}' },
  // ]);

  // A whole new tab:
  // gm.addTab('notes', 'Notes', (el) => {
  //   el.innerHTML = '<div class="card"><h4>Notes</h4><textarea style="width:100%;height:200px"></textarea></div>';
  // });

  // React to server replies:
  // gm.onSystemMessage((text) => { if (/has died/.test(text)) gm.log('Someone died!'); });

  // Everything else: gm.send('.gm on'), await gm.lua('return UnitName("target")'), gm.prompt({...}),
  // gm.target(), gm.here(), gm.wenilla.state (position, target, nearby units).
}
