import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {SceneDocument} from './document.mjs';
import {captureGltfDocument,captureGltfPreview,commitGltfImport} from './gltf-import-edit.mjs';

function candidate(patch={}) {
  return {identifier:'fixture',mdlPath:'models/imports/fixture/model.mdl',bounds:[-1,-2,0,1,2,0],boneCount:2,requiresUnlitConsent:true,
    files:[{path:'models/imports/fixture/model.mdl',data:new Uint8Array([1,2,3])},
      {path:'materials/imports/fixture/body.json',data:new Uint8Array([4,5])},
      {path:'imports/fixture/source/model.gltf',data:new Uint8Array([6,7,8])}],...patch};
}
function fixture() {
  const input={title:'Import',entry:'scene.json',project:{type:'scene'},scene:{objects:[{id:4,name:'Existing',future:{kept:true}}]}};
  const files=new Map([['textures/existing.png',new Uint8Array([9])]]),blobs=new Map();let stages=0;
  const editor={document:new SceneDocument(input),async resourcePaths(){return [...files.keys()];},
    async readResource(path){const version=this.document.snapshot().resourceOverrides?.[path];return (version?blobs.get(version):files.get(path))?.slice()??null;},
    async stageResource(bytes){stages++;const version=createHash('sha256').update(bytes).digest('hex');blobs.set(version,bytes.slice());return version;},
    async change(operation){operation(this.document);}};
  return {editor,input,files,blobs,get stages(){return stages;}};
}
const options=value=>({name:'Imported',origin:[10,20,0],allowUnlit:true,preview:captureGltfPreview(value,64)});

test('model and exact generated/archive bytes publish in one undoable transaction',async()=>{
  const value=fixture(),model=candidate(),source=captureGltfDocument(value.editor),before=structuredClone(model);
  const result=await commitGltfImport(value.editor,source,model,options(model)),snapshot=value.editor.document.snapshot();
  assert.equal(result.id,5);assert.equal(result.mdlPath,model.mdlPath);assert.equal(snapshot.scene.objects.at(-1).model,model.mdlPath);
  assert.equal(snapshot.scene.objects.at(-1).origin,'10 20 0');assert.deepEqual(snapshot.scene.objects[0],value.input.scene.objects[0]);
  assert.equal(Object.keys(snapshot.resourceOverrides).length,3);
  for(const file of model.files)assert.deepEqual(value.blobs.get(snapshot.resourceOverrides[file.path]),file.data);
  assert.deepEqual(model,before);value.editor.document.undo();assert.deepEqual(value.editor.document.snapshot(),value.input);assert.equal(value.editor.document.canUndo,false);
  value.editor.document.redo();assert.deepEqual(value.editor.document.snapshot(),snapshot);
});
test('capture requires actual preview receipt and explicit unlit consent before staging',async()=>{
  for(const patch of [{preview:undefined},{preview:true},{preview:{candidate:null,capacity:64}},{allowUnlit:false}]){
    const value=fixture(),model=candidate();await assert.rejects(commitGltfImport(value.editor,captureGltfDocument(value.editor),model,{...options(model),...patch}),/preview|consent/i);
    assert.equal(value.stages,0);assert.equal(value.editor.document.dirty,false);
  }
  const model=candidate();for(const capacity of [undefined,0,-1,1.5,NaN,1])assert.throws(()=>captureGltfPreview(model,capacity),/capacity|palette/i);
  const value=fixture(),other=candidate();await assert.rejects(commitGltfImport(value.editor,captureGltfDocument(value.editor),other,options(model)),/preview|candidate/i);
});
test('single-sided material conversion requires consent independently of PBR conversion',async()=>{
 const value=fixture(),model=candidate({requiresUnlitConsent:false,requiresTwoSidedConsent:true}),source=captureGltfDocument(value.editor);await assert.rejects(commitGltfImport(value.editor,source,model,{...options(model),allowUnlit:false}),/consent.*two-sided/);assert.equal(value.stages,0);
 const receipt=options(model);model.requiresTwoSidedConsent=false;await assert.rejects(commitGltfImport(value.editor,source,model,receipt),/changed|preview/);
});
test('staging failure or invalid returned immutable version publishes no history',async()=>{
  for(const failure of [1,2,3]){
    const value=fixture(),stage=value.editor.stageResource.bind(value.editor);let count=0;
    value.editor.stageResource=async bytes=>{if(++count===failure)throw new Error('Disk full');return stage(bytes);};const model=candidate();
    await assert.rejects(commitGltfImport(value.editor,captureGltfDocument(value.editor),model,options(model)),/Disk full/);
    assert.deepEqual(value.editor.document.snapshot(),value.input);assert.equal(value.editor.document.canUndo,false);
  }
  const value=fixture(),model=candidate();value.editor.stageResource=async()=> 'invalid';
  await assert.rejects(commitGltfImport(value.editor,captureGltfDocument(value.editor),model,options(model)),/version/i);assert.equal(value.editor.document.dirty,false);
});
test('every asynchronous boundary rejects stale document ownership and content',async()=>{
  for(const boundary of ['resourcePaths','readResource','stageResource','change'])for(const replace of [false,true]){
    const value=fixture(),operation=value.editor[boundary].bind(value.editor);let changed=false;
    value.editor[boundary]=async(...args)=>{
      if(boundary==='change'&&!changed){changed=true;if(replace)value.editor.document=new SceneDocument(value.input);else value.editor.document.rename('Changed');}
      const result=await operation(...args);
      if(boundary!=='change'&&!changed){changed=true;if(replace)value.editor.document=new SceneDocument(value.input);else value.editor.document.rename('Changed');}
      return result;
    };
    const model=candidate();await assert.rejects(commitGltfImport(value.editor,captureGltfDocument(value.editor),model,options(model)),/stale|changed/i);
    assert.equal(value.editor.document.snapshot().scene.objects.length,1);assert.equal(value.editor.document.snapshot().resourceOverrides,undefined);
  }
});
test('destination aliases and file/directory collisions reject before staging',async()=>{
  for(const path of ['models/imports/fixture/model.mdl','MODELS/imports/fixture/model.mdl','models/imports/fixture/model.mdl/child','models/imports','Models/unrelated']){
    const value=fixture(),model=candidate();value.files.set(path,new Uint8Array([7]));
    await assert.rejects(commitGltfImport(value.editor,captureGltfDocument(value.editor),model,options(model)),/collision|ambiguous|exist/i);assert.equal(value.stages,0);
  }
  const value=fixture(),model=candidate({files:[{path:'imports/caf\u00e9.gltf',data:new Uint8Array([1])},{path:'imports/cafe\u0301.gltf',data:new Uint8Array([2])}],mdlPath:'imports/caf\u00e9.gltf'});
  assert.throws(()=>options(model),/collision|ambiguous/i);assert.equal(value.stages,0);
});
test('destinations introduced during staging or final inventory cannot overwrite data',async()=>{
  for(const boundary of ['stageResource','resourcePaths','change'])for(const native of [false,true]){
    const value=fixture(),model=candidate(),operation=value.editor[boundary].bind(value.editor);let count=0;
    const path='MODELS/imports/fixture/model.mdl';
    const inject=()=>{if(native)value.files.set(path,new Uint8Array([99]));else value.editor.document.resource(path,'f'.repeat(64));};
    value.editor[boundary]=async(...args)=>{
      count++;if(boundary==='change'||boundary==='resourcePaths'&&count===2&&native)inject();
      const result=await operation(...args);if(boundary==='stageResource'&&count===1||boundary==='resourcePaths'&&count===2&&!native)inject();return result;
    };
    // Native mutations cannot occur within the synchronous document publication callback.
    if(boundary==='change'&&native)continue;
    await assert.rejects(commitGltfImport(value.editor,captureGltfDocument(value.editor),model,options(model)),/stale|changed|collision|ambiguous|exist/i);
    assert.equal(value.editor.document.snapshot().scene.objects.length,1);assert.equal(value.editor.document.snapshot().resourceOverrides?.[model.mdlPath],undefined);
  }
});
test('preview receipt detects modified candidate data and immutable files are staged with owned bytes',async()=>{
  for(const when of ['before','during']){
    const value=fixture(),model=candidate(),settings=options(model),stage=value.editor.stageResource.bind(value.editor);let changed=false;
    if(when==='before')model.files[0].data[0]=99;
    else value.editor.stageResource=async bytes=>{const result=await stage(bytes);if(!changed){changed=true;model.files[1].data[0]=99;}return result;};
    await assert.rejects(commitGltfImport(value.editor,captureGltfDocument(value.editor),model,settings),/candidate|preview|changed/i);assert.equal(value.editor.document.dirty,false);
  }
  const value=fixture(),model=candidate(),stage=value.editor.stageResource.bind(value.editor);
  value.editor.stageResource=async bytes=>{const result=await stage(bytes);bytes[0]=99;return result;};
  await commitGltfImport(value.editor,captureGltfDocument(value.editor),model,options(model));assert.equal(model.files[0].data[0],1);
});
test('preview receipt rejects deleted candidate files and metadata changes',async()=>{
  for(const mutate of [model=>{delete model.files[0];},model=>{model.boneCount=1;},model=>{model.bounds[0]=-3;},model=>{model.requiresUnlitConsent=false;},model=>{model.files[0].path='changed.mdl';}]){
    const value=fixture(),model=candidate(),settings=options(model);mutate(model);
    await assert.rejects(commitGltfImport(value.editor,captureGltfDocument(value.editor),model,settings),/candidate|preview|changed/i);assert.equal(value.stages,0);
  }
});
test('invalid candidate and placement fail before staging or any document change',async()=>{
  const patches=[{bounds:[0,0,0,0,0,0]},{boneCount:-1},{files:[]},{mdlPath:'missing.mdl'},
    {files:[{path:'../escape',data:new Uint8Array([1])}]},{files:[{path:'bad.mdl',data:[1]}],mdlPath:'bad.mdl'},
    {files:[{path:'scene.json',data:new Uint8Array([1])}],mdlPath:'scene.json'}];
  for(const patch of patches){const value=fixture(),model=candidate(patch);
    await assert.rejects(async()=>commitGltfImport(value.editor,captureGltfDocument(value.editor),model,options(model)));assert.equal(value.stages,0);assert.equal(value.editor.document.dirty,false);
  }
  const value=fixture(),model=candidate();await assert.rejects(commitGltfImport(value.editor,captureGltfDocument(value.editor),model,{...options(model),origin:[Infinity,0,0]}),/origin/i);assert.equal(value.stages,0);
});
