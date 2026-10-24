import { controlled } from './document.mjs';

const $ = id => document.getElementById(id);
const paths = {
  studio:'<rect x="3" y="8" width="14" height="13" rx="3"/><rect x="7" y="3" width="14" height="13" rx="3"/><path d="m9 12 3-4 3 3 3-4 2 5"/>',
  layers:'<path d="m12 3 9 5-9 5-9-5 9-5Z M3 12l9 5 9-5 M3 16l9 5 9-5"/>',
  text:'<path d="M4 7V4h16v3 M12 4v16 M8 20h8"/>',
  image:'<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="1.5"/><path d="m3 17 5-5 4 4 4-6 5 7"/>',
  undo:'<path d="m9 4-5 5 5 5 M4 9h10a6 6 0 0 1 0 12"/>',
  redo:'<path d="m15 4 5 5-5 5 M20 9H10a6 6 0 0 0 0 12"/>',
  plus:'<path d="M12 5v14 M5 12h14"/>',
  copy:'<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M15 8V4H4v11h4"/>',
  trash:'<path d="M4 6h16 M9 6V3h6v3 M6 6l1 15h10l1-15 M10 10v7 M14 10v7"/>',
  up:'<path d="m6 12 6-6 6 6 M12 6v14"/>',
  down:'<path d="m6 12 6 6 6-6 M12 18V4"/>',
  pause:'<path d="M9 5v14 M15 5v14"/>',
  play:'<path d="m8 5 11 7-11 7V5Z"/>',
  theme:'<circle cx="12" cy="12" r="8"/><path d="M12 4v16a8 8 0 0 0 0-16Z" fill="currentColor" stroke="none"/>',
  canvas:'<rect x="3" y="4" width="18" height="14" rx="2"/><path d="M8 21h8 M12 18v3"/>',
  select:'<path d="m5 3 14 9-7 1-3 7-4-17Z"/>',
  lock:'<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3 M12 14v3"/>',
  muted:'<path d="m11 4-5 4H3v8h3l5 4V4Z M16 9l5 6 M21 9l-5 6"/>',
  hidden:'<path d="m3 3 18 18 M10 5h2c5 0 9 7 9 7a20 20 0 0 1-3 4 M6 6a25 25 0 0 0-3 6s4 7 9 7c2 0 3-1 4-2 M10 10a3 3 0 0 0 4 4"/>',
};
function icon(name) {
  if (!paths[name]) throw new Error(`Unknown interface icon: ${name}`);
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox','0 0 24 24'); svg.setAttribute('aria-hidden','true'); svg.classList.add('icon');
  svg.innerHTML = paths[name]; // Static, source-owned paths; project content never enters SVG markup.
  return svg;
}
export function initializeInterface(t) {
  for (const element of document.querySelectorAll('[data-icon]')) element.replaceChildren(icon(element.dataset.icon));
  for (const element of document.querySelectorAll('[data-label]')) {
    element.setAttribute('aria-label',t[element.dataset.label]); element.title = t[element.dataset.label];
  }
  $('theme').addEventListener('change', event => {
    document.querySelector('meta[name="color-scheme"]').content = event.target.value === 'system' ? 'light dark' : event.target.value;
  });
}
export function setPlaybackState(playing, t) {
  $('playback-label').textContent = playing ? t.pause : t.play;
  $('playback-icon').replaceChildren(icon(playing ? 'pause' : 'play'));
  $('playback').setAttribute('aria-pressed',String(playing));
  $('preview-state').textContent = playing ? t.livePreview : t.paused;
  document.querySelector('.preview-status').dataset.paused = String(!playing);
}
function emptySelection(t) {
  const container = document.createElement('div'); container.className = 'panel-empty inspector-empty';
  const image = document.createElement('span'); image.className = 'empty-icon'; image.append(icon('select'));
  const title = document.createElement('h3'); title.textContent = t.selectionTitle;
  const hint = document.createElement('p'); hint.textContent = t.selectionHint;
  container.append(image,title,hint); return container;
}
function renderLayers({layers, selected, onSelect, t}) {
  const items = [...layers].reverse().map(layer => {
    const item = document.createElement('li'), button = document.createElement('button');
    button.type = 'button'; button.className = 'layer-button'; button.dataset.layerId = layer.id;
    button.dataset.visible = String(layer.visible !== false); button.setAttribute('aria-pressed',String(layer.id === selected));
    const name = document.createElement('span'); name.className = 'layer-name'; name.textContent = String(layer.name ?? layer.id); button.title = name.textContent;
    const id = document.createElement('span'); id.className = 'layer-id'; id.textContent = String(layer.id).padStart(2,'0'); id.setAttribute('aria-hidden','true');
    button.append(icon(layer.text !== undefined ? 'text' : layer.image ? 'image' : 'layers'),name);
    if (layer.visible === false) {
      const hidden = icon('hidden'); hidden.classList.add('hidden-indicator'); button.append(hidden);
      button.setAttribute('aria-label',`${name.textContent} (${t.hiddenLayer})`); button.title += ` · ${t.hiddenLayer}`;
    }
    button.append(id);
    button.addEventListener('click',() => onSelect(layer.id)); item.append(button); return item;
  });
  $('layers').replaceChildren(...items); $('layer-count').textContent = String(layers.length); $('layers-empty').hidden = layers.length > 0;
}
function propertyField(layer, key, t, onPatch) {
  const defaults = {name:'',visible:true,origin:'0 0 0',scale:'1 1 1',angles:'0 0 0',color:'1 1 1',alpha:1,pointsize:32};
  const field = document.createElement('div'), label = document.createElement('label'), input = document.createElement(key === 'text' ? 'textarea' : 'input');
  const value = layer[key] ?? defaults[key], bound = controlled(value), numeric = ['alpha','pointsize'].includes(key);
  field.className = 'property-field'; field.dataset.bound = String(Boolean(bound));
  field.dataset.numeric = String(['origin','scale','angles','color','alpha','pointsize'].includes(key));
  input.id = `field-${key}`; label.htmlFor = input.id; label.textContent = t[key]; input.disabled = bound;
  if (bound) { input.title = t.bound; label.append(icon('lock')); }
  if (key === 'visible') { input.type = 'checkbox'; input.checked = bound ? Boolean(value.value) : value; field.classList.add('check-field'); }
  else input.value = bound ? String(value.value ?? '') : String(value);
  if (numeric) { input.type = 'number'; input.step = 'any'; input.min = key === 'alpha' ? '0' : '1'; if (key === 'alpha') input.max = '1'; }
  input.addEventListener('change',() => {
    if (!input.reportValidity()) return;
    onPatch(layer.id,{[key]:key === 'visible' ? input.checked : numeric ? Number(input.value) : input.value});
  });
  field.append(label,input); return field;
}
function renderInspector(layer, t, onPatch) {
  const form = $('inspector');
  if (form.dataset.layerId === String(layer?.id) && form.contains(document.activeElement)) return;
  const selectionChanged = form.dataset.layerId !== String(layer?.id);
  form.dataset.layerId = String(layer?.id); form.replaceChildren();
  if (selectionChanged) form.parentElement.scrollTop = 0;
  $('selection-kind').textContent = layer ? layer.text !== undefined ? t.textLayer : layer.image ? t.imageLayer : t.sceneLayer : '';
  if (!layer) { form.append(emptySelection(t)); return; }
  const groups = [[t.layerSection,['name','visible']],[t.transform,['origin','scale','angles']],[t.appearance,['color','alpha']]];
  if (layer.text !== undefined) groups.splice(1,0,[t.typography,['text','pointsize']]);
  for (const [title, keys] of groups) {
    const group = document.createElement('fieldset'), legend = document.createElement('legend'), fields = document.createElement('div');
    group.className = 'property-group'; legend.textContent = title; fields.className = 'property-fields';
    fields.append(...keys.map(key => propertyField(layer,key,t,onPatch))); group.append(legend,fields); form.append(group);
  }
}
export function renderWorkspace({doc, selected, t, onSelect, onPatch}) {
  const snapshot = doc.snapshot(), layers = snapshot.scene.objects ?? [], layer = layers.find(value => value.id === selected);
  if (document.activeElement !== $('project-title')) $('project-title').value = snapshot.title;
  $('saved').textContent = doc.dirty ? t.unsaved : t.saved; $('saved').dataset.dirty = String(doc.dirty);
  $('undo').disabled = !doc.canUndo; $('redo').disabled = !doc.canRedo;
  for (const id of ['duplicate','remove','up','down']) $(id).disabled = !layer;
  const projection = snapshot.scene.general?.orthogonalprojection;
  $('canvas-size').textContent = projection?.width > 0 && projection?.height > 0 ? `${projection.width} × ${projection.height}` : '';
  renderLayers({layers,selected,onSelect,t}); renderInspector(layer,t,onPatch);
}
