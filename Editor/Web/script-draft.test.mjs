import test from 'node:test';
import assert from 'node:assert/strict';
import { SceneDocument } from './document.mjs';
import { checkSceneScript, inspectSceneScript } from '../Sources/EditorApp/Resources/EditorWeb/script-api.mjs';

const module = await import('../Sources/EditorApp/Resources/EditorWeb/script-draft.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND' && error.url?.endsWith('/script-draft.mjs')) return null;
  throw error;
});
const source = 'export function update(value){ return value; }';
const selection = {layerId:1,target:'color'};
const value = {title:'Scripts',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{objects:[
  {id:1,color:{value:'0 1 0',script:source,future:{kept:true}},alpha:1,origin:'0 0 0'},
]}};
function create(input = value, target = selection) {
  assert.equal(typeof module?.ScriptDraft, 'function', 'Missing ScriptDraft contract');
  const document = new SceneDocument(input);
  return {document,draft:new module.ScriptDraft(document,target)};
}

test('draft captures inspect state and source without editing the document', () => {
  const {document,draft} = create();
  assert.deepEqual(draft.state,inspectSceneScript(value.scene,selection));
  assert.equal(draft.source,source);
  assert.equal(draft.dirty,false);
  assert.deepEqual(draft.diagnostics,[]);
  draft.setSource('export function update(value){ return 0; }');
  assert.equal(draft.dirty,true);
  assert.equal(document.canUndo,false);
  assert.deepEqual(document.snapshot(),value);
});

test('check uses the real compiler without execution and apply adds one undo step', async () => {
  const {document,draft} = create();
  const edited = 'globalThis.__scriptDraftProbe = true;\nexport function update(value){ return 1; }';
  draft.setSource(edited);
  assert.deepEqual(draft.check(),checkSceneScript(edited));
  assert.equal(document.canUndo,false);
  assert.equal(draft.apply(document),true);
  assert.equal(draft.source,edited);
  assert.equal(draft.state.source,edited);
  assert.equal(draft.dirty,false);
  const expected = structuredClone(value); expected.scene.objects[0].color.script = edited;
  assert.deepEqual(document.snapshot(),expected);
  assert.equal(draft.apply(document),false);
  document.undo(); assert.deepEqual(document.snapshot(),value); assert.equal(document.canUndo,false);
  document.redo(); assert.deepEqual(document.snapshot(),expected);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(Object.hasOwn(globalThis,'__scriptDraftProbe'),false);
});

test('syntax errors expose actual compiler line and preserve draft, source and history', () => {
  const {document,draft} = create();
  const invalid = 'export function update(value){\n return (;\n}';
  const actual = checkSceneScript(invalid);
  draft.setSource(invalid);
  for (const operation of [() => draft.check(), () => draft.apply(document)]) {
    assert.throws(operation,error => error.name === 'SceneScriptSyntaxError' && error.message === actual.message && error.line === actual.line);
    assert.deepEqual(draft.diagnostics,[{level:'error',code:'SYNTAX',message:actual.message,line:actual.line}]);
    assert.equal(draft.source,invalid); assert.equal(draft.dirty,true);
    assert.deepEqual(document.snapshot(),value); assert.equal(document.canUndo,false);
  }
});

test('input invalidates earlier Check and exposes NO_ENTRY without invoking the source', () => {
  const {document,draft} = create();
  draft.setSource('export function update(){return 1;}'); draft.check();
  const latest = 'globalThis.__scriptDraftProbe = true;';
  draft.setSource(latest); assert.deepEqual(draft.diagnostics,[]);
  draft.apply(document);
  assert.equal(document.snapshot().scene.objects[0].color.script,latest);
  assert(draft.diagnostics.some(item => item.code === 'NO_ENTRY' && item.level === 'warning'));
  assert.equal(Object.hasOwn(globalThis,'__scriptDraftProbe'),false);
});

test('empty input deliberately adds an empty script while unchanged sources add no history', () => {
  const initial = structuredClone(value); initial.scene.objects[0].color = '0 1 0';
  const {document,draft} = create(initial);
  assert.equal(draft.source,''); assert.equal(draft.dirty,false);
  assert.equal(draft.apply(document),false); assert.equal(document.canUndo,false);
  draft.setSource(''); assert.equal(draft.dirty,true);
  assert.equal(draft.apply(document),true);
  assert.deepEqual(document.snapshot().scene.objects[0].color,{value:'0 1 0',script:''});
  assert.equal(draft.dirty,false); assert.equal(draft.apply(document),false);
  document.undo(); assert.deepEqual(document.snapshot(),initial); assert.equal(document.canUndo,false);
  const existing = create(); existing.draft.setSource(source);
  assert.equal(existing.draft.dirty,false); assert.equal(existing.draft.apply(existing.document),false);
  assert.equal(existing.document.canUndo,false);
});

test('remove explicitly discards invalid draft and preserves the wrapper with a single history step', () => {
  const {document,draft} = create(); draft.setSource('export function update( {');
  assert.equal(draft.remove(document),true);
  assert.deepEqual(document.snapshot().scene.objects[0].color,{value:'0 1 0',future:{kept:true}});
  assert.equal(draft.source,''); assert.equal(draft.dirty,false); assert.deepEqual(draft.diagnostics,[]);
  assert.equal(draft.remove(document),false);
  document.undo(); assert.deepEqual(document.snapshot(),value); assert.equal(document.canUndo,false);
  const initial = structuredClone(value); initial.scene.objects[0].color = '0 1 0';
  const constant = create(initial); constant.draft.setSource(source);
  assert.equal(constant.draft.remove(constant.document),false);
  assert.equal(constant.draft.dirty,false); assert.equal(constant.document.canUndo,false);
});

test('stale or replaced documents reject apply and remove without erasing draft', () => {
  for (const operation of ['apply','remove']) {
    for (const checked of [false,true]) {
      const {document,draft} = create(); const edited = 'export function update(){ return 1; }';
      draft.setSource(edited); if (checked) draft.check();
      const replaced = new SceneDocument(value);
      assert.throws(() => draft[operation](replaced),/document|stale|changed/i);
      assert.deepEqual(replaced.snapshot(),value); assert.equal(replaced.canUndo,false);
      document.rename('Changed'); const stale = document.snapshot();
      assert.throws(() => draft[operation](document),/document|stale|changed/i);
      assert.deepEqual(document.snapshot(),stale); assert.equal(draft.source,edited); assert.equal(draft.dirty,true);
    }
  }
});

test('revert deliberately adopts a current or replacement document after conflict', () => {
  const {document,draft} = create(); draft.setSource('broken(');
  const replacement = new SceneDocument(value);
  replacement.script({...selection,type:'set',source:'export function update(){ return 2; }'});
  assert.throws(() => draft.apply(replacement),/document|stale|changed/i);
  draft.revert(replacement);
  assert.equal(draft.source,replacement.snapshot().scene.objects[0].color.script);
  assert.equal(draft.dirty,false); assert.deepEqual(draft.diagnostics,[]);
  draft.setSource(source); assert.equal(draft.apply(replacement),true);
  assert.deepEqual(document.snapshot(),value);
});

test('object member order is immaterial while full snapshot array changes are stale', () => {
  const initial = structuredClone(value); initial.scene.metadata = [1,2];
  const {document,draft} = create(initial); const snapshot = document.snapshot.bind(document);
  draft.setSource('export function update(){return 1;}'); draft.check();
  document.snapshot = () => Object.fromEntries(Object.entries(snapshot()).reverse());
  assert.equal(draft.apply(document),true);
  draft.setSource(source);
  document.snapshot = () => {const current = snapshot(); current.scene.metadata.reverse(); return current;};
  assert.throws(() => draft.apply(document),/stale|changed/i);
  assert.equal(draft.source,source); assert.equal(draft.dirty,true);
});

test('unmodified CRLF, Unicode and mixed source bytes remain exact through apply and serialization', () => {
  for (const text of ['// 雪 ☃ 😀\r\nexport function update(value){\r\n return value;\r\n}', '// 雪\r\nexport function update(value){\n return value;\r\n}']) {
    const initial = structuredClone(value); initial.scene.objects[0].color.script = text;
    const {document,draft} = create(initial);
    assert.equal(draft.source,text); draft.check(); assert.equal(draft.apply(document),false);
    assert.equal(document.canUndo,false);
    assert.equal(new SceneDocument(JSON.parse(JSON.stringify(document.snapshot()))).snapshot().scene.objects[0].color.script,text);
    const edited = `${text}\r\n// 新`;
    draft.setSource(edited); draft.apply(document);
    assert.equal(document.snapshot().scene.objects[0].color.script,edited);
  }
});

test('malformed source and unsupported anchors fail explicitly and cannot mutate exposed state', () => {
  const {document,draft} = create();
  for (const invalid of [undefined,null,42,{},'a\0b','\ud800']) {
    assert.throws(() => draft.setSource(invalid),/string|NUL|Unicode|source/i);
    assert.equal(draft.source,source); assert.equal(draft.dirty,false);
  }
  const exposed = draft.state; exposed.source = 'changed'; exposed.value = '1 1 1';
  assert.equal(draft.state.source,source); assert.deepEqual(document.snapshot(),value);
  assert.throws(() => new module.ScriptDraft(null,selection),/document/i);
  const bound = structuredClone(value); bound.scene.objects[0].color.user = 'bound';
  for (const target of [selection,{layerId:1,target:'unknown'}]) {
    const blocked = create(bound,target);
    assert.equal(blocked.draft.state.editable,false);
    for (const operation of [() => blocked.draft.setSource(source),() => blocked.draft.check(),() => blocked.draft.apply(blocked.document),() => blocked.draft.remove(blocked.document)]) assert.throws(operation,/binding|target|supported/i);
    assert.equal(blocked.document.canUndo,false);
  }
});

test('selection belongs to the draft and effect source keeps unknown wrapper data', () => {
  const initial = structuredClone(value);
  initial.scene.objects[0].effects = [{visible:{value:true,script:source,future:['kept']},name:'effect'}];
  const target = {layerId:1,target:'effects[0].visible'};
  const {document,draft} = create(initial,target);
  target.target = 'alpha';
  const edited = 'export function update(value){return false;}';
  draft.setSource(edited); draft.check(); draft.apply(document);
  assert.deepEqual(document.snapshot().scene.objects[0].effects[0].visible,{value:true,script:edited,future:['kept']});
  assert.equal(document.snapshot().scene.objects[0].alpha,1);
  draft.remove(document);
  assert.deepEqual(document.snapshot().scene.objects[0].effects[0].visible,{value:true,future:['kept']});
});

test('snapshot staleness covers unrelated nested members and sparse array length', () => {
  for (const mutate of [
    current => { current.project.description = 'changed'; },
    current => { current.scene.objects[0].color.future.kept = false; },
    current => { current.scene.metadata.length = 1; },
  ]) {
    const initial = structuredClone(value); initial.scene.metadata = [];
    const {document,draft} = create(initial), snapshot = document.snapshot.bind(document);
    draft.setSource('export function update(){return 1;}'); draft.check();
    document.snapshot = () => {const current = snapshot(); mutate(current); return current;};
    assert.throws(() => draft.apply(document),/stale|changed/i);
    assert.equal(document.canUndo,false); assert.equal(draft.dirty,true);
  }
});

test('restoring only local input never adopts a changed document baseline',()=>{
 const doc=new SceneDocument(value),draft=new module.ScriptDraft(doc,{layerId:1,target:'alpha'});
 draft.setSource('export function update(v){return v;}');doc.rename('External change');
 assert.equal(typeof draft.restoreInput,'function');draft.restoreInput();assert.equal(draft.dirty,false);
 assert.throws(()=>draft.apply(doc),/stale|changed/);draft.revert(doc);draft.setSource('');assert.equal(draft.dirty,true);
});
