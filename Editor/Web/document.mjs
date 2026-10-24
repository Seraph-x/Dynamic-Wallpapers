export function safePath(value) {
  if (typeof value !== 'string' || !value || /[\\:\0]/.test(value) || value.split('/').some(p => !p || p === '.' || p === '..')) throw new Error('Invalid project resource path');
  return value;
}
export const controlled = value => value !== null && typeof value === 'object';
const clone = value => structuredClone(value);
const object = value => value && typeof value === 'object' && !Array.isArray(value);
// Native JSON dictionaries may reorder keys. Arrays retain meaningful scene/layer order.
const equivalent = (left, right) => {
  if (left === right) return true;
  if (Array.isArray(left)) return Array.isArray(right) && left.length === right.length && left.every((value, index) => equivalent(value, right[index]));
  if (!object(left) || !object(right)) return false;
  const keys = Object.keys(left);
  return keys.length === Object.keys(right).length && keys.every(key => Object.hasOwn(right, key) && equivalent(left[key], right[key]));
};

export class SceneDocument {
  #value; #saved; #undo = []; #redo = [];
  constructor(value) {
    if (!object(value) || !object(value.scene) || !object(value.project) || value.project.type !== 'scene' ||
        (value.scene.objects !== undefined && !Array.isArray(value.scene.objects)) || typeof value.title !== 'string' || !value.title.trim()) throw new Error('Invalid scene document');
    safePath(value.entry);
    this.#value = clone(value); this.#saved = clone(value);
  }
  snapshot() { return clone(this.#value); }
  get dirty() { return !equivalent(this.#value, this.#saved); }
  get canUndo() { return this.#undo.length > 0; }
  get canRedo() { return this.#redo.length > 0; }
  markSaved(snapshot = this.#value) { this.#saved = clone(snapshot); }
  undo() { if (!this.canUndo) return; this.#redo.push(this.#value); this.#value = this.#undo.pop(); }
  redo() { if (!this.canRedo) return; this.#undo.push(this.#value); this.#value = this.#redo.pop(); }
  #change(operation) {
    const next = clone(this.#value); const result = operation(next);
    if (!equivalent(next, this.#value)) { this.#undo.push(this.#value); this.#redo = []; this.#value = next; }
    return result;
  }
  #layer(value, id) {
    const layer = value.scene.objects?.find(layer => layer.id === id);
    if (!layer) throw new Error('Layer does not exist'); return layer;
  }
  #nextID(value) {
    const ids = (value.scene.objects ?? []).map(o => o.id).filter(Number.isSafeInteger);
    const id = ids.reduce((largest, id) => Math.max(largest, id), 0) + 1;
    if (!Number.isSafeInteger(id)) throw new Error('Layer IDs exhausted'); return id;
  }
  patch(id, patch) {
    return this.#change(value => {
      const layer = this.#layer(value, id);
      for (const [key, data] of Object.entries(patch)) {
        if (!['name', 'visible', 'alpha', 'origin', 'scale', 'angles', 'color', 'text', 'pointsize'].includes(key)) throw new Error('Unsupported layer field');
        if (controlled(layer[key])) throw new Error('This field is controlled by a script, animation or property binding');
        if (['origin', 'scale', 'angles', 'color'].includes(key)) {
          const values = typeof data === 'string' ? data.trim().split(/\s+/).map(Number) : [];
          if (values.length !== 3 || !values.every(Number.isFinite) || (key === 'color' && values.some(n => n < 0 || n > 1))) throw new Error('Expected three finite components');
        } else if (key === 'visible' ? typeof data !== 'boolean' : ['alpha', 'pointsize'].includes(key) ?
          !Number.isFinite(data) || (key === 'alpha' ? data < 0 || data > 1 : data <= 0) : typeof data !== 'string') throw new Error('Invalid field value');
        layer[key] = data;
      }
    });
  }
  rename(title) {
    if (typeof title !== 'string' || !title.trim()) throw new Error('A project title is required');
    this.#change(value => { value.title = title; });
  }
  addText(text) {
    if (typeof text !== 'string') throw new Error('Text must be a string');
    return this.#change(value => {
      const id = this.#nextID(value), canvas = value.scene.general?.orthogonalprojection;
      (value.scene.objects ??= []).push({ id, name: text || 'Text', text, font: 'systemfont_arial', pointsize: 32,
        origin: `${(canvas?.width ?? 1920) / 2} ${(canvas?.height ?? 1080) / 2} 0`, scale: '1 1 1', angles: '0 0 0',
        size: '600 100', color: '1 1 1', alpha: 1, horizontalalign: 'center', verticalalign: 'center', padding: 32 });
      return id;
    });
  }
  addImage(image) {
    safePath(image.model);
    if (![image.width, image.height].every(n => Number.isFinite(n) && n > 0) || typeof image.name !== 'string') throw new Error('Invalid image');
    return this.#change(value => {
      const id = this.#nextID(value), canvas = value.scene.general?.orthogonalprojection;
      const width = canvas?.width ?? 1920, height = canvas?.height ?? 1080;
      const scale = Math.min(1, width * 0.8 / image.width, height * 0.8 / image.height);
      (value.scene.objects ??= []).push({ id, name: image.name, image: image.model,
        origin: `${width / 2} ${height / 2} 0`, scale: `${scale} ${scale} 1`, angles: '0 0 0', color: '1 1 1', alpha: 1 });
      return id;
    });
  }
  duplicate(id) {
    return this.#change(value => { const layer = clone(this.#layer(value, id)); layer.id = this.#nextID(value);
      layer.name = `${layer.name ?? id} copy`; value.scene.objects.push(layer); return layer.id; });
  }
  remove(id) { this.#change(value => { this.#layer(value, id); value.scene.objects = value.scene.objects.filter(o => o.id !== id); }); }
  move(id, delta) {
    if (![1, -1].includes(delta)) throw new Error('Invalid layer move');
    this.#change(value => { this.#layer(value, id); const layers = value.scene.objects, index = layers.findIndex(o => o.id === id);
      const other = index + delta; if (other >= 0 && other < layers.length) [layers[index], layers[other]] = [layers[other], layers[index]]; });
  }
}
