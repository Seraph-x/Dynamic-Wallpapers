import { createScene } from './webwallgl.bundle.mjs';
import { editorOf, buildScenePkg, checkWeCompat } from './editor-api.mjs';
import { controlled } from './document.mjs';
import { startEditor } from './runtime.mjs';
import { messages } from './localization.mjs';

const $ = id => document.getElementById(id);
let editor, selected, drag, editFailure;
document.body.inert = true;
const showError = error => { $('diagnostics').textContent = String(error?.message ?? error); };
try {
  const response = await fetch('/__editor/config', { redirect: 'error' });
  if (!response.ok) throw new Error(`Editor configuration: HTTP ${response.status}`);
  const config = await response.json(), t = messages(config.language);
  document.documentElement.lang = config.language ?? 'en';
  for (const element of document.querySelectorAll('[data-text]')) element.textContent = t[element.dataset.text];
  const report = async payload => {
    const response = await fetch('/__editor/event', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload), redirect: 'error' });
    if (!response.ok) throw new Error(`Editor event: HTTP ${response.status}`);
  };
  const act = operation => {
    editFailure = undefined;
    $('diagnostics').textContent = '';
    return editor.change(operation).catch(error => { editFailure = error; showError(error); });
  };
  function update(doc) {
    const snapshot = doc.snapshot(), layers = snapshot.scene.objects ?? [];
    if (document.activeElement !== $('project-title')) $('project-title').value = snapshot.title;
    $('saved').textContent = doc.dirty ? t.unsaved : t.saved;
    $('undo').disabled = !doc.canUndo; $('redo').disabled = !doc.canRedo;
    $('layers').replaceChildren();
    for (const layer of [...layers].reverse()) {
      const item = document.createElement('li'), button = document.createElement('button');
      button.type = 'button'; button.textContent = String(layer.name ?? layer.id); button.dataset.layerId = layer.id;
      button.setAttribute('aria-pressed', String(selected === layer.id));
      button.addEventListener('click', () => { selected = layer.id; update(doc); }); item.append(button); $('layers').append(item);
    }
    const layer = layers.find(layer => layer.id === selected);
    for (const id of ['duplicate','remove','up','down']) $(id).disabled = !layer;
    if ($('inspector').dataset.layerId === String(selected) && $('inspector').contains(document.activeElement)) return;
    $('inspector').dataset.layerId = String(selected); $('inspector').replaceChildren();
    if (!layer) { $('inspector').textContent = t.empty; return; }
    const defaults = { name:'',visible:true,origin:'0 0 0',scale:'1 1 1',angles:'0 0 0',color:'1 1 1',alpha:1,pointsize:32 };
    const fields = ['name','visible','origin','scale','angles','color','alpha', ...(layer.text !== undefined ? ['text','pointsize'] : [])];
    for (const key of fields) {
      const label = document.createElement('label'), input = document.createElement(key === 'text' ? 'textarea' : 'input');
      const value = layer[key] ?? defaults[key], bound = controlled(value);
      input.id = `field-${key}`; label.htmlFor = input.id; label.textContent = t[key];
      input.disabled = bound; if (bound) input.title = t.bound;
      if (key === 'visible') { input.type = 'checkbox'; input.checked = bound ? Boolean(value.value) : value; }
      else { input.value = bound ? String(value.value ?? '') : String(value); }
      if (['alpha','pointsize'].includes(key)) { input.type = 'number'; input.step = 'any'; input.min = key === 'alpha' ? '0' : '1'; if (key === 'alpha') input.max = '1'; }
      input.addEventListener('change', () => {
        if (!input.reportValidity()) return;
        void act(doc => doc.patch(selected, { [key]: key === 'visible' ? input.checked : ['alpha','pointsize'].includes(key) ? Number(input.value) : input.value }));
      });
      $('inspector').append(label, input);
    }
  }
  editor = startEditor(config, { createScene, editorOf, buildScenePkg, checkWeCompat, element:$('canvas'), report, onChange:update, onError:showError,
    setEditingEnabled: value => { document.body.inert = !value; }, snapshotError: () => editFailure });
  async function finishDrag() {
    if (!drag) return;
    const pending = drag; drag = undefined;
    if (pending.position) await act(doc => doc.patch(pending.id, {origin:pending.position.join(' ')}));
  }
  window.__dynamicWallpaperEditor = Object.freeze({ command: async value => {
    if (['snapshot','freeze'].includes(value.type)) {
      // Native menu/close commands do not necessarily blur the CEF text field.
      // Commit the visible value and pending drag before taking its snapshot.
      const focused = document.activeElement;
      const invalid = focused?.checkValidity && !focused.checkValidity() ? focused.validationMessage : undefined;
      focused?.blur(); await finishDrag();
      if (invalid) { editFailure = new Error(invalid); showError(editFailure); }
    }
    return editor.command(value);
  } });
  $('playback').textContent = t.pause;
  $('playback').addEventListener('click', () => {
    editor.setPlaying(!editor.playing); $('playback').textContent = editor.playing ? t.pause : t.play;
    $('playback').setAttribute('aria-pressed', String(editor.playing));
  });
  $('project-title').addEventListener('change', event => void act(doc => doc.rename(event.target.value)));
  for (const [id, operation] of Object.entries({ undo:doc => doc.undo(),redo:doc => doc.redo(),
    'add-text':doc => { selected = doc.addText(t.newText); },duplicate:doc => { selected = doc.duplicate(selected); },
    remove:doc => { doc.remove(selected); selected = undefined; },up:doc => doc.move(selected,1),down:doc => doc.move(selected,-1) })) $(id).addEventListener('click', () => void act(operation));
  $('inspector').addEventListener('submit', event => event.preventDefault());
  $('canvas').addEventListener('pointerdown', event => {
    const bounds = $('canvas').getBoundingClientRect(), hit = editor.controls?.hitTestAt(event.clientX-bounds.left,event.clientY-bounds.top);
    if (hit?.length) {
      selected = hit[0].id; update(editor.document);
      const snapshot = editor.document.snapshot(), layer = snapshot.scene.objects.find(o => o.id === selected), projection = snapshot.scene.general?.orthogonalprojection;
      if (layer && !controlled(layer.origin) && projection?.width > 0 && projection?.height > 0) {
        const props = editor.controls.getLayerProps(selected);
        if (props) {
          drag = {id:selected,x:event.clientX,y:event.clientY,origin:props.origin,
            scale:Math.min(bounds.width/projection.width,bounds.height/projection.height)};
          $('canvas').setPointerCapture(event.pointerId);
        }
      }
    }
  });
  $('canvas').addEventListener('pointermove', event => {
    if (!drag) return;
    drag.position = [drag.origin[0]+(event.clientX-drag.x)/drag.scale,drag.origin[1]-(event.clientY-drag.y)/drag.scale,drag.origin[2]];
    void editor.controls.setLayerProps(drag.id,{origin:drag.position}).catch(showError);
  });
  for (const name of ['pointerup','pointercancel']) $('canvas').addEventListener(name, () => void finishDrag().catch(showError));
  document.addEventListener('keydown', event => {
    if (document.body.inert) return;
    if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== 'z' || /INPUT|TEXTAREA/.test(event.target.tagName)) return;
    event.preventDefault(); void act(doc => event.shiftKey ? doc.redo() : doc.undo());
  });
  await editor.ready;
  window.addEventListener('pagehide', () => editor.destroy(), { once:true });
} catch (error) { showError(error); console.error('Editor preparation failed',error); }
