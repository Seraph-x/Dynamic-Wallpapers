import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { inspectModel } from './model.mjs';
import { SceneDocument } from './document.mjs';
import { captureImageSource,commitImagePuppet } from './image-puppet-edit.mjs';

const encode=value=>new TextEncoder().encode(JSON.stringify(value));
function fixture(stage) {
  const input={title:'Images',entry:'scene.json',project:{type:'scene'},scene:{objects:[
    {id:1,name:'Picture',image:'models/picture.json',origin:'40 30 0',scale:'2 2 1',future:{kept:true}},
    {id:2,name:'Shared',image:'models/picture.json',origin:'100 30 0'}]}};
  const files=new Map([['models/picture.json',encode({material:'materials/picture.json',width:80,height:40,future:true})],['materials/picture.json',encode({passes:[{shader:'genericimage2',textures:['picture']}],future:true})]]);
  const blobs=new Map();
  const editor={document:new SceneDocument(input),controls:{getModelInfo:()=>null},async readResource(path){return files.get(path)?.slice()??null;},
    async resourcePaths(){return [...files.keys()];},
    async stageResource(bytes){if(stage)await stage(bytes);const hash=createHash('sha256').update(bytes).digest('hex');blobs.set(hash,bytes.slice());return hash;},
    async change(operation){operation(this.document);}};
  return {editor,input,files,blobs};
}
const settings={columns:4,rows:4,rootName:'Root',identifier:'test-image'};
test('image conversion publishes three resources and only one layer binding in one undo step',async()=>{
  const {editor,input,blobs}=fixture(),source=captureImageSource(editor,1);
  const result=await commitImagePuppet(editor,source,settings),value=editor.document.snapshot();
  assert.equal(Object.keys(value.resourceOverrides).length,3);assert.equal(blobs.size,3);
  assert.equal(value.scene.objects[0].image,result.modelPath);assert.notEqual(result.modelPath,input.scene.objects[0].image);
  assert.deepEqual({...value.scene.objects[0],image:input.scene.objects[0].image},input.scene.objects[0]);assert.deepEqual(value.scene.objects[1],input.scene.objects[1]);
  editor.document.undo();assert.deepEqual(editor.document.snapshot(),input);assert.equal(editor.document.canUndo,false);editor.document.redo();assert.deepEqual(editor.document.snapshot(),value);
});
test('failed second/third staging publishes no partial conversion',async()=>{
  for(const failed of [2,3]){let calls=0;const {editor,input}=fixture(async()=>{if(++calls===failed)throw new Error('Disk full');});
    await assert.rejects(commitImagePuppet(editor,captureImageSource(editor,1),settings),/Disk full/);assert.deepEqual(editor.document.snapshot(),input);assert.equal(editor.document.canUndo,false);
  }
});
test('destination collision and stale image/material/document changes cannot overwrite data',async()=>{
  for(const change of [e=>{e.document=new SceneDocument(e.document.snapshot());},e=>e.document.resource('materials/picture.json','a'.repeat(64)),e=>e.document.retargetImage(1,'models/picture.json','other.json')]){
    let mutated=false;const value=fixture(async()=>{if(!mutated){mutated=true;change(value.editor);}}),source=captureImageSource(value.editor,1);
    await assert.rejects(commitImagePuppet(value.editor,source,settings),/changed|stale/i);
    assert.equal(value.editor.document.snapshot().resourceOverrides?.['models/test-image.puppet-model.json'],undefined);
  }
  const value=fixture();value.files.set('models/test-image.puppet.mdl',new Uint8Array([7]));
  await assert.rejects(commitImagePuppet(value.editor,captureImageSource(value.editor,1),settings),/exist|collision/i);assert.equal(value.editor.document.dirty,false);
  assert.throws(()=>captureImageSource(value.editor,99));
});

test('destinations introduced during the final asynchronous check are never overwritten',async()=>{
  for(const path of ['models/test-image.puppet-model.json','MODELS/TEST-IMAGE.PUPPET-MODEL.JSON','models/test-image.puppet-model.json/child']){
    const {editor}=fixture(),read=editor.readResource.bind(editor);let calls=0;
    editor.readResource=async name=>{const result=await read(name);if(++calls===8)editor.document.resource(path,'f'.repeat(64));return result;};
    await assert.rejects(commitImagePuppet(editor,captureImageSource(editor,1),settings),/exist|collision|ambiguous/i);
    assert.deepEqual(editor.document.snapshot().resourceOverrides,{[path]:'f'.repeat(64)});
    assert.equal(editor.document.snapshot().scene.objects[0].image,'models/picture.json');
  }
});

test('conversion derives grid dimensions from the selected layer size',async()=>{
  const {editor}=fixture(),input=editor.document.snapshot();input.scene.objects[0].size={value:'160 80'};editor.document=new SceneDocument(input);
  const result=await commitImagePuppet(editor,captureImageSource(editor,1),settings);
  assert.deepEqual([...inspectModel(result.files[0].data).meshes[0].positions.slice(0,3)],[-80,40,0]);
  assert.deepEqual(editor.document.snapshot().scene.objects[0].size,input.scene.objects[0].size);
});

test('original resource aliases and file/directory collisions reject conversion before publication',async()=>{
  for(const path of ['models/test-image.puppet-model.json/child','MODELS/TEST-IMAGE.PUPPET-MODEL.JSON','Models/unrelated']){
    const {editor,files}=fixture();files.set(path,new Uint8Array([7]));
    await assert.rejects(commitImagePuppet(editor,captureImageSource(editor,1),settings),/exist|collision|ambiguous/i);
    assert.equal(editor.document.dirty,false);
  }
});
