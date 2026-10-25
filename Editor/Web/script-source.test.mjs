import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectSceneScript, editSceneScript, listSceneScripts } from './script-source.mjs';
import { SceneDocument } from './document.mjs';

const source = 'export function update(value) { return value; }';
const scene = (fields = {}) => ({objects:[{id:1,name:'Layer',origin:'1 2 3',...fields}],future:{keep:[1,2]}});
const select = (target = 'origin') => ({layerId:1,target});
const set = (target = 'origin', text = source) => ({...select(target),type:'set',source:text});
const workspace = value => ({scene:value,project:{type:'scene'},title:'Scripts',entry:'scene.json'});

test('inspects owned constants and creates an owned wrapper without changing input', () => {
  const input = scene({scale:[1,2,3]}), before = structuredClone(input);
  assert.deepEqual(inspectSceneScript(input,select()),{kind:'constant',value:'1 2 3',editable:true});
  const state = inspectSceneScript(input,select('scale')); state.value[0] = 8;
  const output = editSceneScript(input,set());
  assert.deepEqual(output.objects[0].origin,{value:'1 2 3',script:source});
  output.future.keep.push(3);
  assert.deepEqual(input,before);
});

test('native core defaults are precise and optional fields require existing bases', () => {
  const input = {objects:[{id:1}]};
  for (const [target,value] of Object.entries({origin:'0 0 0',angles:'0 0 0',scale:'1 1 1',color:'1 1 1',alpha:1,visible:true})) {
    assert.deepEqual(editSceneScript(input,set(target)).objects[0][target],{value,script:source});
  }
  for (const target of ['brightness','maxwidth','pointsize','volume','intensity','exponent','text']) {
    assert.equal(inspectSceneScript(input,select(target)).editable,false);
    assert.throws(() => editSceneScript(input,set(target)));
  }
});

test('native optional scalar, text and effect anchors retain primitive bases', () => {
  const input = scene({brightness:-2,maxwidth:0,pointsize:2,volume:.25,intensity:3,exponent:4,text:'你好',effects:[{visible:false}]});
  for (const target of ['brightness','maxwidth','pointsize','volume','intensity','exponent','text','effects[0].visible']) {
    assert.equal(inspectSceneScript(input,select(target)).editable,true,target);
    const output = editSceneScript(input,set(target));
    assert.equal(inspectSceneScript(output,select(target)).source,source);
  }
  for (const target of ['effects[1].visible','effects[-1].visible','effects[00].visible','effects[0].alpha','future.keep','constructor','__proto__']) {
    assert.equal(inspectSceneScript(input,select(target)).kind,'unsupported');
    assert.throws(() => editSceneScript(input,set(target)));
  }
});

test('existing wrappers retain unknown fields and scriptproperties, including absent value', () => {
  for (const wrapper of [{value:.75,script:source,scriptproperties:{script:'metadata',settings:{a:1}},future:[1]},
    {script:source,scriptproperties:{script:{future:true}},future:[2]}]) {
    const input = scene({alpha:wrapper}), output = editSceneScript(input,set('alpha','replacement'));
    assert.deepEqual(output.objects[0].alpha,{...wrapper,script:'replacement'});
    const removed = editSceneScript(output,{...select('alpha'),type:'remove'});
    const expected = {...wrapper}; delete expected.script;
    assert.deepEqual(removed.objects[0].alpha,expected);
    assert.deepEqual(input.objects[0].alpha,wrapper);
  }
});

test('binding conflicts and malformed wrappers cannot be edited', () => {
  for (const wrapper of [{value:1,user:'x'},{value:1,animation:{}},{value:1,user:'x',animation:{},script:source},
    {value:1,script:12},{value:'wrong',script:source},{future:true},{value:NaN},{value:Infinity},null,[],true]) {
    const input = scene({alpha:wrapper}), before = structuredClone(input), state = inspectSceneScript(input,select('alpha'));
    assert.equal(state.editable,false,JSON.stringify(wrapper));
    for (const type of ['set','remove']) assert.throws(() => editSceneScript(input,{...set('alpha'),type}));
    assert.deepEqual(input,before);
  }
  assert.equal(inspectSceneScript(scene({alpha:{value:1,user:'x',script:source}}),select('alpha')).kind,'bound');
});

test('base validation accepts finite vectors without numeric normalization', () => {
  for (const value of [' 1e2  -0  .5 ',[1,-0,.5]]) {
    const input = scene({origin:value});
    assert.deepEqual(editSceneScript(input,set()).objects[0].origin.value,value);
  }
  for (const value of ['', '1 2', '1 nope 3', [1,2,Infinity],['1',2,3],[1,,3],{x:1,y:2,z:3}]) {
    assert.equal(inspectSceneScript(scene({origin:value}),select()).editable,false);
  }
  assert.equal(inspectSceneScript(scene({visible:1}),select('visible')).editable,false);
  assert.equal(inspectSceneScript(scene({text:17}),select('text')).editable,false);
});

test('wrapped constants and absent effect visibility preserve all metadata', () => {
  const input = scene({alpha:{value:.5,scriptproperties:{script:'custom metadata'},future:{a:1}},effects:[{name:'Existing effect'}]});
  const output = editSceneScript(input,set('alpha'));
  assert.deepEqual(output.objects[0].alpha,{...input.objects[0].alpha,script:source});
  assert.deepEqual(editSceneScript(input,{...select('alpha'),type:'remove'}),input);
  assert.deepEqual(editSceneScript(input,set('effects[0].visible')).objects[0].effects[0],{name:'Existing effect',visible:{value:true,script:source}});
});

test('ambiguous source anchors stay registered and discovery scans nested source objects', () => {
  const input = {objects:[{id:1,alpha:{script:source}},{id:1,alpha:{script:17}},
    {origin:{script:source},metadata:{script:{script:'another metadata member'}}}]};
  const found = listSceneScripts(input);
  assert.deepEqual(found.map(item => item.registered),[true,true,true,false,false]);
  assert(found.every(item => !item.editable));
  assert.match(found[0].reason,/duplicate/i); assert.match(found[2].reason,/ID/);
  assert.deepEqual(found.at(-1).path,['objects',2,'metadata','script','script']);
});

test('owned copies preserve shared JSON values without mistaking them for cycles', () => {
  const shared = {note:'same'}, input = scene({metadata:shared}); input.future = shared;
  const result = editSceneScript(input,set());
  result.future.note = 'owned'; assert.equal(input.future.note,'same');
  assert.deepEqual(listSceneScripts(input),[]);
});

test('editing one anchor does not change shared wrappers, effects or layer-list metadata', () => {
  const wrapper={value:1,script:source}, effect={visible:{value:true,script:source}};
  const input=scene({alpha:wrapper,brightness:wrapper,effects:[effect,effect]});
  input.future=input.objects;
  for(const type of ['set','remove']){
    const output=editSceneScript(input,{...set('alpha','new source'),type});
    assert.deepEqual(output.objects[0].brightness,wrapper);
    assert.deepEqual(output.future,input.future);
    const changed=editSceneScript(input,{...set('effects[0].visible','new source'),type});
    assert.deepEqual(changed.objects[0].effects[1],effect);
    assert.deepEqual(changed.future,input.future);
  }
});

test('source strings preserve CRLF, astral Unicode, empty text and never execute', () => {
  const text = 'globalThis.__scriptSourceProbe = true;\r\n// 😀 你好\r\nthrow new Error("never");';
  for (const exact of [text,'']) assert.equal(editSceneScript(scene(),set('origin',exact)).objects[0].origin.script,exact);
  assert.equal(globalThis.__scriptSourceProbe,undefined);
  for (const invalid of [null,1,{},'a\0b','\ud800','\udc00','x\ud800y']) assert.throws(() => editSceneScript(scene(),set('origin',invalid)));
});

test('ambiguous and missing layer identities and invalid edits reject visibly', () => {
  for (const input of [{objects:[{origin:'0 0 0'}]}, {objects:[{id:1},{id:1}]}, {objects:[]}, {objects:{}}]) {
    assert.equal(inspectSceneScript(input,select()).editable,false);
    assert.throws(() => editSceneScript(input,set()));
  }
  for (const edit of [null,{}, {...set(),layerId:undefined},{...set(),type:'compile'}]) assert.throws(() => editSceneScript(scene(),edit));
});

test('discovery records stable native paths, bound scripts and unknown nested metadata', () => {
  const input = scene({alpha:{value:1,script:source,user:'property',scriptproperties:{script:'metadata'}},
    effects:[{visible:{value:true,script:'effect'}}],future:{script:{metadata:true}},text:{value:'text',script:12}});
  input.extra = {script:'outside'};
  const found = listSceneScripts(input);
  assert.deepEqual(found.map(item => item.path),[
    ['objects',0,'alpha','script'],['objects',0,'alpha','scriptproperties','script'],
    ['objects',0,'effects',0,'visible','script'],['objects',0,'future','script'],['objects',0,'text','script'],['extra','script'],
  ]);
  assert.deepEqual(found.filter(item => item.registered).map(item => [item.target,item.editable]),[['alpha',false],['effects[0].visible',true],['text',false]]);
  assert(found.filter(item => !item.registered).every(item => !item.editable && item.reason));
  assert.equal(found[0].layerId,1); assert.equal(found[2].source,'effect');
  found[3].source.metadata = false; assert.equal(input.objects[0].future.script.metadata,true);
});

test('discovery rejects cycles explicitly and handles deeply nested JSON iteratively', () => {
  const cyclic = scene(); cyclic.future.self = cyclic;
  for (const operation of [() => listSceneScripts(cyclic), () => inspectSceneScript(cyclic,select()), () => editSceneScript(cyclic,set())]) {
    assert.throws(operation,/cycl/i);
  }
  const input = scene(); let cursor = input.future;
  for (let index = 0; index < 12000; index++) { cursor.child = {}; cursor = cursor.child; }
  cursor.script = 'deep metadata';
  const found = listSceneScripts(input); assert.equal(found.length,1); assert.equal(found[0].registered,false);
  assert.equal(editSceneScript(input,set()).objects[0].origin.script,source);
});

test('removing a constant and setting identical source create no document history', () => {
  const input = workspace(scene()), doc = new SceneDocument(input);
  doc.script({...select(),type:'remove'}); assert.equal(doc.canUndo,false); assert.equal(doc.dirty,false);
  doc.script(set()); const changed = doc.snapshot(); assert.equal(doc.canUndo,true);
  doc.script(set()); doc.undo(); assert.deepEqual(doc.snapshot(),input); assert.equal(doc.canUndo,false);
  doc.redo(); assert.deepEqual(doc.snapshot(),changed);
  doc.script({...select(),type:'remove'}); assert.deepEqual(doc.snapshot().scene.objects[0].origin,{value:'1 2 3'});
  doc.undo(); assert.deepEqual(doc.snapshot(),changed);
});

test('source errors preserve undo and redo history, and document set is source-only', () => {
  const input = workspace(scene()), doc = new SceneDocument(input);
  doc.script(set('origin','this is intentionally invalid syntax ;')); doc.undo();
  assert.throws(() => doc.script(set('origin','\ud800'))); assert.equal(doc.canRedo,true);
  assert.deepEqual(doc.snapshot(),input); doc.redo(); assert.equal(doc.canUndo,true);
});
