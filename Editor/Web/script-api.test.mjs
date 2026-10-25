import test from 'node:test';
import assert from 'node:assert/strict';
import { checkSceneScript,prepareSceneScript,applySceneScript,checkSceneScriptSources } from '../Sources/EditorApp/Resources/EditorWeb/script-api.mjs';
import { SceneDocument } from './document.mjs';
const source='export function update(value){ return value; }';
const value={title:'Scripts',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{objects:[{id:1,color:{value:'0 1 0',script:source,future:{kept:true}},alpha:1,origin:'0 0 0'}]}};
const edit={layerId:1,target:'color',type:'set',source:'export function update(value){return {x:1,y:0,z:0};}'};

test('the actual pinned compiler loads without DOM and never executes source',async()=>{
 assert.equal(typeof window,'undefined');assert.equal(typeof document,'undefined');
 for(const prefix of ['globalThis.__sceneCompileProbe=true;','throw new Error("body ran");','Function("globalThis.__sceneCompileProbe=true")();','setTimeout(()=>globalThis.__sceneCompileProbe=true,0);','fetch("http://127.0.0.1:1/compile-probe");','import("http://127.0.0.1:1/compile-probe.mjs");']){
  const result=checkSceneScript(prefix+'\n'+source);assert.equal(result.ok,true,result.message);
 }
 await new Promise(resolve=>setImmediate(resolve));assert.equal(Object.hasOwn(globalThis,'__sceneCompileProbe'),false);
});
test('checked source proposals update only the wrapper and round trip through history',()=>{
 const doc=new SceneDocument(value),proposal=prepareSceneScript(doc,edit);assert.deepEqual(doc.snapshot(),value);assert(Object.isFrozen(proposal));applySceneScript(doc,proposal);
 const expected=structuredClone(value);expected.scene.objects[0].color.script=edit.source;assert.deepEqual(doc.snapshot(),expected);doc.undo();assert.deepEqual(doc.snapshot(),value);doc.redo();assert.deepEqual(doc.snapshot(),expected);assert.deepEqual(new SceneDocument(JSON.parse(JSON.stringify(doc.snapshot()))).snapshot(),expected);
});
test('syntax failure reports the actual compiler location and leaves history unchanged',()=>{
 const doc=new SceneDocument(value),bad={...edit,source:'export function update(value){\nreturn (;\n}'};let failure;try{prepareSceneScript(doc,bad);}catch(error){failure=error;}
 assert.equal(failure?.name,'SceneScriptSyntaxError');assert.equal(failure.target,'color');assert.equal(failure.layerId,1);assert.equal(failure.check.ok,false);assert(Number.isInteger(failure.line)&&failure.line>0);assert.deepEqual(doc.snapshot(),value);assert.equal(doc.canUndo,false);
});
test('no-entry source carries an explicit warning and compilation is not execution',()=>{
 const doc=new SceneDocument(value),proposal=prepareSceneScript(doc,{...edit,source:'globalThis.__sceneCompileProbe=true;'});assert(proposal.diagnostics.some(d=>d.code==='NO_ENTRY'&&d.level==='warning'));assert.equal(Object.hasOwn(globalThis,'__sceneCompileProbe'),false);applySceneScript(doc,proposal);assert.equal(Object.hasOwn(globalThis,'__sceneCompileProbe'),false);
});
test('source proposals own their edit, reject forged/replayed/stale documents',()=>{
 const doc=new SceneDocument(value),request={...edit},proposal=prepareSceneScript(doc,request);request.source='throw new Error("changed")';applySceneScript(doc,proposal);assert.equal(doc.snapshot().scene.objects[0].color.script,edit.source);assert.throws(()=>applySceneScript(doc,proposal),/proposal|consumed|available/i);assert.throws(()=>applySceneScript(doc,{...proposal}),/proposal/i);
 const stale=prepareSceneScript(doc,{...edit,source});doc.rename('Changed');const before=doc.snapshot();assert.throws(()=>applySceneScript(doc,stale),/stale|changed/i);assert.deepEqual(doc.snapshot(),before);assert.throws(()=>applySceneScript(new SceneDocument(value),prepareSceneScript(doc,edit)),/stale|document/i);
});
test('source no-ops do not add history, removal is data-only, and proposals stay consumed',()=>{
 const doc=new SceneDocument(value),noOp=prepareSceneScript(doc,{...edit,source});applySceneScript(doc,noOp);assert.equal(doc.canUndo,false);const removed=prepareSceneScript(doc,{layerId:1,target:'color',type:'remove'});assert.equal(removed.check,null);applySceneScript(doc,removed);assert.deepEqual(doc.snapshot().scene.objects[0].color,{value:'0 1 0',future:{kept:true}});doc.undo();assert.deepEqual(doc.snapshot(),value);
});
test('reports compile only registered anchors and retain custom metadata unvalidated',()=>{
 const scene=structuredClone(value.scene);scene.objects[0].color.scriptproperties={script:{label:'custom metadata'}};scene.objects[0].custom={script:'not valid code !!!!'};scene.objects[0].alpha={value:1,user:'alpha',script:source};scene.objects[0].origin={value:'0 0 0',script:7};
 const report=checkSceneScriptSources(scene);assert.equal(report.scope,'inline-native-scene-scripts');assert.equal(report.discovered,5);assert.equal(report.checked,3);assert.equal(report.unvalidated,2);assert.equal(report.errors,1);assert.equal(report.ok,false);for(const result of report.results.filter(r=>!r.registered)){assert.equal(result.checked,false);assert.equal(result.check,null);assert(result.diagnostics.every(d=>d.level==='info'));}assert.equal(report.results.find(r=>r.target==='alpha').check.ok,true);assert.equal(report.results.find(r=>r.target==='alpha').editable,false);
});
test('malformed scene and invalid edits fail explicitly without fake compile success',()=>{
 assert.throws(()=>checkSceneScriptSources(null));assert.throws(()=>prepareSceneScript(new SceneDocument(value),{...edit,target:'image'}),/target|supported/i);assert.throws(()=>prepareSceneScript(new SceneDocument(value),{...edit,source:'bad\0source'}),/NUL|Unicode|source/i);
});

test('proposal snapshots ignore object member order but retain array order and length',()=>{
 const input=structuredClone(value);input.scene.metadata=[1,2];
 const doc=new SceneDocument(input),snapshot=doc.snapshot.bind(doc),proposal=prepareSceneScript(doc,edit);
 const reordered=()=>{const actual=snapshot();return Object.fromEntries(Object.entries(actual).reverse());};
 doc.snapshot=reordered;applySceneScript(doc,proposal);assert.equal(snapshot().scene.objects[0].color.script,edit.source);
 const changed=prepareSceneScript(doc,{...edit,source});doc.snapshot=()=>{const actual=reordered();actual.scene.metadata.reverse();return actual;};
 assert.throws(()=>applySceneScript(doc,changed),/stale/);
 const sparse=new SceneDocument({...input,scene:{...input.scene,metadata:[]}}),sparseSnapshot=sparse.snapshot.bind(sparse);
 const pinned=prepareSceneScript(sparse,edit);sparse.snapshot=()=>{const actual=sparseSnapshot();actual.scene.metadata.length=1;return actual;};
 assert.throws(()=>applySceneScript(sparse,pinned),/stale/);
});
