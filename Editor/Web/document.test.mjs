import test from 'node:test';
import assert from 'node:assert/strict';
import { SceneDocument } from './document.mjs';

const initial = () => ({ scene: { general: { orthogonalprojection: { width: 800, height: 600 } }, objects: [
  { id: 1, name: 'Bound', origin: { value: '0 0 0', script: 'export function update(v) {return v;}' }, future: { a: 1 } },
], future: [1, 2] }, project: { type: 'scene', file: 'nested.json', future: true }, entry: 'nested.json', title: 'Title' });
test('edits, undo and redo preserve unknown metadata and never mutate input', () => {
  const input = initial(), doc = new SceneDocument(input);
  doc.patch(1, { name: 'Renamed', visible: false, alpha: 0.5 });
  assert.equal(input.scene.objects[0].name, 'Bound');
  assert.equal(doc.snapshot().scene.objects[0].name, 'Renamed');
  assert.deepEqual(doc.snapshot().scene.future, [1, 2]);
  assert.equal(doc.snapshot().project.future, true);
  assert(doc.dirty); doc.undo(); assert.deepEqual(doc.snapshot(), input); assert(!doc.dirty);
  doc.redo(); assert.equal(doc.snapshot().scene.objects[0].name, 'Renamed');
  doc.markSaved(); assert(!doc.dirty); doc.undo(); assert(doc.dirty);
});
test('controlled fields and invalid values fail without changing history', () => {
  const doc = new SceneDocument(initial());
  for (const patch of [{ origin: '1 2 3' }, { alpha: NaN }, { alpha: -1 }, { scale: 'NaN 1 1' }, { future: 5 }]) {
    assert.throws(() => doc.patch(1, patch));
    assert.deepEqual(doc.snapshot(), initial());
  }
});
test('text/image, duplicate, reorder and remove are fully undoable', () => {
  const doc = new SceneDocument(initial());
  const text = doc.addText('Hello'); const image = doc.addImage({ name: 'Cloud', model: 'models/editor/a.json', width: 200, height: 100 });
  assert.equal(doc.snapshot().scene.objects.find(o => o.id === text).text, 'Hello');
  const duplicate = doc.duplicate(image);
  assert.notEqual(duplicate, image); doc.move(duplicate, -1); doc.remove(text);
  for (let i = 0; i < 6; ++i) doc.undo();
  assert.deepEqual(doc.snapshot(), initial());
  for (let i = 0; i < 6; ++i) doc.redo();
  assert.equal(doc.snapshot().scene.objects.length, 3);
});
test('invalid imports and missing layers surface explicit errors', () => {
  assert.throws(() => new SceneDocument({ ...initial(), scene: [] }));
  const doc = new SceneDocument(initial());
  assert.throws(() => doc.patch(42, { name: 'Missing' }));
  assert.throws(() => doc.addImage({ name: 'A', model: '../bad.json', width: 1, height: 1 }));
  assert.throws(() => doc.addImage({ name: 'A', model: 'a.json', width: 0, height: 1 }));
});
