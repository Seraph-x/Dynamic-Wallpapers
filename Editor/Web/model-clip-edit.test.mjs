import test from 'node:test';
import assert from 'node:assert/strict';
import { SceneDocument } from './document.mjs';
import { captureClipSource,inspectClipReferences,commitClipResource,commitClipPlayback } from './model-clip-edit.mjs';
import { modelFixture } from './model-fixtures.mjs';

const encode=value=>new TextEncoder().encode(JSON.stringify(value));
const modelBytes=modelFixture();
function fixture() {
  const input={title:'Clips',entry:'scene.json',project:{type:'scene'},scene:{objects:[
    {id:1,name:'Selected',model:'models/rig.mdl',future:{keep:true}},
    {id:2,name:'Hidden puppet',image:'models/puppet.json',visible:false,animationlayers:[{animation:7,visible:false,blend:0}]},
    {id:3,name:'Ordinary image',image:'models/image.json',animationlayers:{script:'not a model'}},
    {id:4,name:'Default direct',model:'models/rig.mdl',animationlayers:[]},
    {id:5,name:'Other model',model:'models/other.mdl',animationlayers:{value:[]}},
    {id:6,name:'Text',text:'Hello'},
  ]}};
  const files=new Map([['models/rig.mdl',new Uint8Array(modelBytes)],['models/puppet.json',encode({puppet:'models/rig.mdl',material:'materials/rig.json'})],['models/image.json',encode({material:'materials/image.json'})]]);
  const calls={stages:0,changes:0,reads:[]};
  const editor={document:new SceneDocument(input),controls:{getModelInfo:id=>id===1?{mdlPath:'models/rig.mdl'}:null},
    async readResource(path){calls.reads.push(path);return files.get(path)?.slice()??null;},
    async stageResource(bytes){calls.stages++;calls.bytes=bytes;return 'a'.repeat(64);},
    async change(operation){calls.changes++;operation(this.document);}};
  return {editor,input,files,calls};
}
const settle=()=>new Promise(resolve=>setImmediate(resolve));
test('clip source captures an immutable document pin and scans hidden shared puppets and direct model defaults',async()=>{
  const {editor,input,calls}=fixture(),source=captureClipSource(editor,1,modelBytes);
  assert(Object.isFrozen(source));assert(Object.isFrozen(source.snapshot.scene.objects[0].future));
  assert.throws(()=>{source.snapshot.scene.objects[0].model='other.mdl';},TypeError);
  const references=await inspectClipReferences(editor,source);
  assert.deepEqual(references.referenced,[7]);
  assert.deepEqual(references.defaults,[{id:1,name:'Selected'},{id:4,name:'Default direct'}]);
  assert.deepEqual(references.layers.map(({id,path,default:useDefault,referenced})=>({id,path,default:useDefault,referenced})),[
    {id:1,path:'models/rig.mdl',default:true,referenced:[]},
    {id:2,path:'models/rig.mdl',default:false,referenced:[7]},
    {id:4,path:'models/rig.mdl',default:true,referenced:[]},
  ]);
  assert(calls.reads.includes('models/puppet.json'));assert.deepEqual(editor.document.snapshot(),input);
});
test('a loaded MDL resource does not need a particular filename suffix to retain shared references',async()=>{
 const {editor,files}=fixture(),input=editor.document.snapshot();for(const layer of input.scene.objects)if(layer.model==='models/rig.mdl')layer.model='models/rig.data';editor.document=new SceneDocument(input);editor.controls.getModelInfo=id=>id===1?{mdlPath:'models/rig.data'}:null;files.set('models/rig.data',modelBytes);files.set('models/puppet.json',encode({puppet:'models/rig.data',material:'materials/rig.json'}));const refs=await inspectClipReferences(editor,captureClipSource(editor,1,modelBytes));assert.deepEqual(refs.referenced,[7]);assert.equal(refs.layers.length,3);
});
test('playback assignment cannot publish through a puppet JSON whose model binding changed',async()=>{
 const {editor,files,calls}=fixture();editor.controls.getModelInfo=id=>[1,2].includes(id)?{mdlPath:'models/rig.mdl'}:null;const source=captureClipSource(editor,2,modelBytes);await inspectClipReferences(editor,source);files.set('models/puppet.json',encode({puppet:'models/other.mdl',material:'materials/rig.json'}));await assert.rejects(commitClipPlayback(editor,source,7),/changed|disagrees|stale/i);assert.equal(calls.changes,0);
});
test('unreferenced clip resource stages an owned byte copy once and publishes exactly one undoable revision',async()=>{
  const {editor,input,calls}=fixture(),source=captureClipSource(editor,1,modelBytes),bytes=new Uint8Array([2,3]);
  await commitClipResource(editor,source,bytes,{deletedID:9});
  assert.notEqual(calls.bytes,bytes);assert.deepEqual(calls.bytes,bytes);assert.equal(calls.stages,1);assert.equal(calls.changes,1);
  assert.equal(editor.document.snapshot().resourceOverrides['models/rig.mdl'],'a'.repeat(64));
  assert.deepEqual(editor.document.snapshot().scene,input.scene);
  editor.document.undo();assert.deepEqual(editor.document.snapshot(),input);assert.equal(editor.document.canUndo,false);
});
test('deleting a numeric explicit reference blocks staging even for invisible animation entries',async()=>{
  const {editor,input,calls}=fixture();
  await assert.rejects(commitClipResource(editor,captureClipSource(editor,1,modelBytes),new Uint8Array([1]),{deletedID:7}),/referenced|playback/i);
  assert.equal(calls.stages,0);assert.equal(calls.changes,0);assert.deepEqual(editor.document.snapshot(),input);
});
test('ambiguous controlled tables and non-native animation entries fail explicitly on shared models',async()=>{
  for(const table of [{value:[]},'7',[7],[{animation:'7'}],[{animation:{value:7}}],[{animation:NaN}],[{}],[{animation:-1}],[{animation:2**32}]]){
    const {editor,calls}=fixture(),snapshot=editor.document.snapshot();snapshot.scene.objects[1].animationlayers=table;editor.document=new SceneDocument(snapshot);
    await assert.rejects(commitClipResource(editor,captureClipSource(editor,1,modelBytes),new Uint8Array([1]),{deletedID:9}),/animation|controlled|reference/i);
    assert.equal(calls.stages,0);assert.equal(editor.document.canUndo,false);
  }
});
test('ordinary clip metadata updates preserve controlled scene tables without replacing them',async()=>{
  const {editor}=fixture(),snapshot=editor.document.snapshot();snapshot.scene.objects[1].animationlayers={value:[],script:'return table;'};editor.document=new SceneDocument(snapshot);
  await commitClipResource(editor,captureClipSource(editor,1,modelBytes),new Uint8Array([1]));
  assert.deepEqual(editor.document.snapshot().scene,snapshot.scene);
});
test('missing, malformed and controlled image metadata cannot be assumed unshared',async()=>{
  for(const invalid of [null,encode([]),encode({puppet:{value:'models/rig.mdl'}}),encode({puppet:'../rig.mdl'}),new Uint8Array([0xff])]){
    const {editor,files,calls}=fixture();if(invalid===null)files.delete('models/image.json');else files.set('models/image.json',invalid);
    await assert.rejects(inspectClipReferences(editor,captureClipSource(editor,1,modelBytes)),/image|JSON|resource|path|encoding|encoded/i);
    assert.equal(calls.stages,0);
  }
});
test('case aliases, model metadata disagreements and ambiguous bound paths fail rather than losing references',async()=>{
  for(const modify of [
    ({files})=>files.set('models/puppet.json',encode({puppet:'Models/Rig.mdl'})),
    ({editor})=>{editor.controls.getModelInfo=id=>id===1?{mdlPath:'models/rig.mdl'}:id===2?{mdlPath:'models/other.mdl'}:null;},
    ({editor})=>{const input=editor.document.snapshot();input.scene.objects.push({id:8,image:{value:'models/puppet.json'}});editor.document=new SceneDocument(input);},
  ]){
    const value=fixture();modify(value);
    await assert.rejects(inspectClipReferences(value.editor,captureClipSource(value.editor,1,modelBytes)),/ambiguous|path|model|controlled/i);
  }
});
test('document, source revision and any shared binding drift during a resource read reject before staging',async()=>{
  for(const modify of [
    editor=>{editor.document=new SceneDocument(editor.document.snapshot());},
    editor=>editor.document.resource('models/rig.mdl','b'.repeat(64)),
    editor=>editor.document.patch(2,{name:'Changed shared layer'}),
    editor=>{editor.controls.getModelInfo=()=>({mdlPath:'models/other.mdl'});},
    editor=>editor.document.resource('models/puppet.json','b'.repeat(64)),
  ]){
    const {editor,calls}=fixture(),source=captureClipSource(editor,1,modelBytes),read=editor.readResource.bind(editor);let resume;
    editor.readResource=path=>{editor.readResource=read;return new Promise(resolve=>{resume=()=>read(path).then(resolve);});};
    const pending=commitClipResource(editor,source,new Uint8Array([1]),{deletedID:9});await settle();modify(editor);resume();
    await assert.rejects(pending,/changed|stale/i);assert.equal(calls.stages,0);
  }
});
test('failed staging and document or image-content drift while staging never publish a resource',async()=>{
  const failure=fixture();failure.editor.stageResource=async()=>{throw new Error('Disk full');};
  await assert.rejects(commitClipResource(failure.editor,captureClipSource(failure.editor,1,modelBytes),new Uint8Array([1])),/Disk full/);
  assert.deepEqual(failure.editor.document.snapshot(),failure.input);assert.equal(failure.calls.changes,0);
  for(const modify of [
    ({editor})=>editor.document.patch(2,{name:'Edited during stage'}),
    ({files})=>files.set('models/puppet.json',encode({puppet:'models/other.mdl'})),
    ({editor})=>editor.document.resource('models/puppet.json','c'.repeat(64)),
  ]){
    const value=fixture(),source=captureClipSource(value.editor,1,modelBytes);let resume;
    value.editor.stageResource=()=>new Promise(resolve=>{resume=()=>resolve('a'.repeat(64));});
    const pending=commitClipResource(value.editor,source,new Uint8Array([1]),{deletedID:9});await settle();modify(value);resume();
    await assert.rejects(pending,/changed|stale/i);assert.equal(value.calls.changes,0);
    assert.equal(value.editor.document.snapshot().resourceOverrides?.['models/rig.mdl'],undefined);
  }
});
test('deferred document publication rechecks its complete ownership pin',async()=>{
  const {editor,calls}=fixture(),source=captureClipSource(editor,1,modelBytes);let publish;
  editor.change=operation=>new Promise((resolve,reject)=>{publish=()=>{try{operation(editor.document);resolve();}catch(error){reject(error);}};});
  const pending=commitClipResource(editor,source,new Uint8Array([1]));await settle();editor.document.patch(1,{name:'Changed after stage'});publish();
  await assert.rejects(pending,/changed|stale/i);assert.equal(calls.stages,1);assert.equal(editor.document.snapshot().resourceOverrides,undefined);
});
test('explicit playback commits only the selected layer and undo restores opaque native bindings',async()=>{
  const {editor}=fixture(),input=editor.document.snapshot();input.scene.objects[0].animationlayers={value:[{animation:99}],script:'return table;',unknown:[1,2]};editor.document=new SceneDocument(input);
  await commitClipPlayback(editor,captureClipSource(editor,1,modelBytes),7);
  assert.deepEqual(editor.document.snapshot().scene.objects[0].animationlayers,[{animation:7,blend:1,rate:1,visible:true}]);
  assert.deepEqual(editor.document.snapshot().scene.objects.slice(1),input.scene.objects.slice(1));
  editor.document.undo();assert.deepEqual(editor.document.snapshot(),input);
  await commitClipPlayback(editor,captureClipSource(editor,1,modelBytes),null);assert.equal(Object.hasOwn(editor.document.snapshot().scene.objects[0],'animationlayers'),false);
  editor.document.undo();assert.deepEqual(editor.document.snapshot(),input);
});
test('playback assignment refuses stale ownership without changing the native table',async()=>{
  const {editor}=fixture(),source=captureClipSource(editor,1,modelBytes);editor.document.patch(2,{name:'Changed'});const before=editor.document.snapshot();
  await assert.rejects(commitClipPlayback(editor,source,7),/changed|stale/i);assert.deepEqual(editor.document.snapshot(),before);
});
test('the resource candidate is owned before asynchronous metadata reads, including typed array subclasses',async()=>{
  const {editor,calls}=fixture(),source=captureClipSource(editor,1,modelBytes),bytes=Buffer.from([3,4]),read=editor.readResource.bind(editor);let resume;
  editor.readResource=path=>{editor.readResource=read;return new Promise(resolve=>{resume=()=>read(path).then(resolve);});};
  const pending=commitClipResource(editor,source,bytes);await settle();bytes.fill(99);resume();await pending;
  assert.deepEqual([...calls.bytes],[3,4]);
});
test('captured sources and JSON resource pins cannot be forged or mutated between reference scans',async()=>{
  const value=fixture(),source=captureClipSource(value.editor,1,modelBytes);
  await assert.rejects(inspectClipReferences(value.editor,{...source}),/captured|source/i);
  await inspectClipReferences(value.editor,source);value.files.set('models/image.json',encode({material:'materials/changed.json'}));
  await assert.rejects(inspectClipReferences(value.editor,source),/changed|stale/i);
});

 test('capture requires loaded model bytes and owns typed array subclass storage',async()=>{
  const {editor}=fixture();
  for(const bytes of [undefined,null,[],new ArrayBuffer(8)])assert.throws(()=>captureClipSource(editor,1,bytes),/bytes/i);
  const loaded=Buffer.from(modelBytes),source=captureClipSource(editor,1,loaded);loaded.fill(0);
  await inspectClipReferences(editor,source);
 });
 test('MDL host drift before commit rejects candidates made from the loaded source',async()=>{
  for(const action of ['inspect','resource','playback']){
   const {editor,files,calls}=fixture(),source=captureClipSource(editor,1,modelBytes);files.set('models/rig.mdl',Uint8Array.of(88));
   const pending=action==='inspect'?inspectClipReferences(editor,source):action==='resource'?commitClipResource(editor,source,Uint8Array.of(9)):commitClipPlayback(editor,source,7);
   await assert.rejects(pending,/model|changed|stale/i);assert.equal(calls.stages,0);assert.equal(calls.changes,0);
  }
 });
 test('MDL host drift during initial image metadata read rejects before staging',async()=>{
  const {editor,files,calls}=fixture(),source=captureClipSource(editor,1,modelBytes),read=editor.readResource.bind(editor);let resume;
  let intercepted=false;
  editor.readResource=path=>{if(path==='models/puppet.json'&&!intercepted){intercepted=true;return new Promise(resolve=>{resume=()=>read(path).then(resolve);});}return read(path);};
  const pending=commitClipResource(editor,source,Uint8Array.of(9));await settle();files.set('models/rig.mdl',Uint8Array.of(88));resume();
  await assert.rejects(pending,/model|changed|stale/i);assert.equal(calls.stages,0);assert.equal(calls.changes,0);
 });
 test('MDL host drift during staging or after staging blocks publication',async()=>{
  for(const phase of ['stage','metadata']){
   const {editor,files,calls}=fixture(),source=captureClipSource(editor,1,modelBytes),read=editor.readResource.bind(editor);let staged=false;
   editor.stageResource=async()=>{calls.stages++;staged=true;if(phase==='stage')files.set('models/rig.mdl',Uint8Array.of(88));return 'a'.repeat(64);};
   editor.readResource=async path=>{const bytes=await read(path);if(phase==='metadata'&&staged&&path==='models/puppet.json')files.set('models/rig.mdl',Uint8Array.of(88));return bytes;};
   await assert.rejects(commitClipResource(editor,source,Uint8Array.of(9)),/model|changed|stale/i);assert.equal(calls.stages,1);assert.equal(calls.changes,0);assert.equal(editor.document.snapshot().resourceOverrides,undefined);
  }
 });
 test('reference rescans and playback reject MDL content drift despite unchanged revision',async()=>{
  const {editor,files,calls}=fixture(),source=captureClipSource(editor,1,modelBytes);await inspectClipReferences(editor,source);files.set('models/rig.mdl',Uint8Array.of(88));
  await assert.rejects(inspectClipReferences(editor,source),/model|changed|stale/i);await assert.rejects(commitClipPlayback(editor,source,7),/model|changed|stale/i);assert.equal(calls.changes,0);
 });
