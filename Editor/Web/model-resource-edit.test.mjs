import test from 'node:test';
import assert from 'node:assert/strict';
import { SceneDocument } from './document.mjs';
import { modelResourceSource,commitModelResource } from './model-resource-edit.mjs';

const initial=()=>new SceneDocument({title:'Owned',entry:'scene.json',project:{type:'scene'},scene:{objects:[{id:1,image:'rig.json'}]}});
function editor(stage) {return {document:initial(),controls:{getModelInfo:id=>id===1?{mdlPath:'rig.mdl'}:null},
  stageResource:stage,async change(operation){operation(this.document);}};}
test('resource commits stage bytes before exactly one undoable document edit',async()=>{
  const value=editor(async bytes=>{assert.deepEqual(bytes,new Uint8Array([1,2]));return 'a'.repeat(64);}),source=modelResourceSource(value,1);
  await commitModelResource(value,source,new Uint8Array([1,2]));assert.equal(value.document.snapshot().resourceOverrides['rig.mdl'],'a'.repeat(64));
  value.document.undo();assert.equal(value.document.canUndo,false);assert.equal(value.document.dirty,false);
});
test('failed staging and replaced documents never receive an edit',async()=>{
  const failure=editor(async()=>{throw new Error('Disk full');});
  await assert.rejects(commitModelResource(failure,modelResourceSource(failure,1),new Uint8Array([1])),/Disk full/);assert.equal(failure.document.dirty,false);
  let finish;const value=editor(()=>new Promise(resolve=>{finish=resolve;})),old=value.document,source=modelResourceSource(value,1);
  const pending=commitModelResource(value,source,new Uint8Array([1]));await Promise.resolve();value.document=initial();finish('b'.repeat(64));
  await assert.rejects(pending,/changed|stale/i);assert.equal(old.dirty,false);assert.equal(value.document.dirty,false);
});
test('concurrent revision changes and model retargets reject stale writes',async()=>{
  for(const modify of [value=>value.document.resource('rig.mdl','c'.repeat(64)),value=>{value.controls.getModelInfo=()=>({mdlPath:'other.mdl'});}]){
    let finish;const value=editor(()=>new Promise(resolve=>{finish=resolve;})),source=modelResourceSource(value,1);
    const pending=commitModelResource(value,source,new Uint8Array([1]));await Promise.resolve();modify(value);finish('b'.repeat(64));
    await assert.rejects(pending,/changed|stale/i);assert.notEqual(value.document.snapshot().resourceOverrides?.['rig.mdl'],'b'.repeat(64));
  }
});
