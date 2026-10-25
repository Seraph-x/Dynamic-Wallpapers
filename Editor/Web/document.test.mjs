import test from 'node:test';
import assert from 'node:assert/strict';
import { SceneDocument } from './document.mjs';

const initial = () => ({ scene: { general: { orthogonalprojection: { width: 800, height: 600 } }, objects: [
  { id: 1, name: 'Bound', origin: { value: '0 0 0', script: 'export function update(v) {return v;}' }, future: { a: 1 } },
], future: [1, 2] }, project: { type: 'scene', file: 'nested.json', future: true }, entry: 'nested.json', title: 'Title' });
test('native save acknowledgements may reorder object fields but not scene arrays', () => {
  const reorder = value => Array.isArray(value) ? value.map(reorder) : value && typeof value === 'object'
    ? Object.fromEntries(Object.entries(value).reverse().map(([key, value]) => [key, reorder(value)])) : value;
  const doc = new SceneDocument(initial());
  doc.patch(1, { name: 'Saved through native bridge' });
  const acknowledgement = reorder(doc.snapshot());
  doc.markSaved(acknowledgement);
  assert.equal(doc.dirty, false);
  acknowledgement.title = 'External mutation';
  assert.equal(doc.dirty, false);
  doc.undo(); assert.equal(doc.dirty, true);
  doc.redo(); assert.equal(doc.dirty, false);
  const wrongOrder = reorder(doc.snapshot());
  wrongOrder.scene.future.reverse(); doc.markSaved(wrongOrder);
  assert.equal(doc.dirty, true);
});
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
test('JSON and immutable resource versions commit as one transaction with exact undo', () => {
  const input = initial(), doc = new SceneDocument(input), version = 'a'.repeat(64);
  doc.transaction(draft => { draft.patch(1,{name:'New model'}); draft.resource('models/body.mdl',version); });
  assert.equal(doc.snapshot().scene.objects[0].name,'New model');
  assert.deepEqual(doc.snapshot().resourceOverrides,{'models/body.mdl':version});
  doc.undo(); assert.deepEqual(doc.snapshot(),input); assert.equal(doc.canUndo,false);
  doc.redo(); assert.equal(doc.snapshot().resourceOverrides['models/body.mdl'],version);
  doc.markSaved(); assert.equal(doc.dirty,false);
  doc.transaction(draft => draft.resource('models/body.mdl',version));
  doc.undo(); assert.deepEqual(doc.snapshot(),input,'No-op transaction added history');
  doc.redo(); const before = doc.snapshot();
  assert.throws(() => doc.transaction(draft => { draft.patch(1,{name:'Invalid'}); draft.resource('../escape',version); }));
  assert.deepEqual(doc.snapshot(),before); assert.equal(doc.canRedo,false);
  assert.throws(() => doc.transaction(draft => draft.resource('nested.json',version)));
});
test('transaction can remove the final override and restore it with undo', () => {
  const version='a'.repeat(64), doc=new SceneDocument({...initial(),resourceOverrides:{'body.mdl':version}});
  doc.transaction(draft => {draft.resource('body.mdl',null);draft.patch(1,{name:'Original resource'});});
  assert.equal(doc.snapshot().resourceOverrides,undefined);
  doc.undo(); assert.equal(doc.snapshot().resourceOverrides['body.mdl'],version);
  doc.redo(); assert.equal(doc.snapshot().resourceOverrides,undefined);
});
test('resource edits reject reserved aliases, duplicate identities and malformed imported maps', () => {
  const doc=new SceneDocument(initial()), version='a'.repeat(64);
  for(const path of ['Project.JSON','NESTED.JSON']) assert.throws(()=>doc.resource(path,version));
  assert.throws(()=>new SceneDocument({...initial(),resourceOverrides:{'a.bin':null}}));
  assert.throws(()=>new SceneDocument({...initial(),resourceOverrides:{'a.bin':version,'A.bin':version}}));
  doc.resource('__proto__',version);assert.equal(doc.snapshot().resourceOverrides.__proto__,version);
  const unicode=new SceneDocument({...initial(),entry:'scènes.json'});
  assert.throws(()=>unicode.resource('SCE\u0300NES.JSON',version));
});
test('model insertion validates bounds and placement before one undoable layer change', () => {
  const input=initial(),doc=new SceneDocument(input),settings={model:'models/imported/scene.mdl',name:'Imported model',bounds:[-2,-1,0,2,3,0]};
  const id=doc.addModel(settings),layer=doc.snapshot().scene.objects.find(value=>value.id===id);
  assert.deepEqual(layer,{id:2,name:'Imported model',model:settings.model,origin:'400 300 0',scale:'1 1 1',angles:'0 0 0',size:'4 4',color:'1 1 1',alpha:1});
  doc.undo();assert.deepEqual(doc.snapshot(),input);assert.equal(doc.canUndo,false);doc.redo();
  assert.equal(doc.snapshot().scene.objects.at(-1).model,settings.model);
  const next=doc.addModel({...settings,origin:[10,-20,3]});assert.equal(doc.snapshot().scene.objects.find(value=>value.id===next).origin,'10 -20 3');
  const before=doc.snapshot();
  for(const patch of [{model:'../escape.mdl'},{name:''},{bounds:[0,0,0,Infinity,1,1]},{bounds:[1,0,0,0,1,1]},{bounds:[0,0,0,0,0,0]},{bounds:[0,0,1,1,1]},{origin:[1,2]},{origin:[0,NaN,0]}]){
    assert.throws(()=>doc.addModel({...settings,...patch}));assert.deepEqual(doc.snapshot(),before);
  }
});
