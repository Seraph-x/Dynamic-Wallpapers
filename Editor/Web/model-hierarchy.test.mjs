import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectModel } from './model.mjs';
import { editModelHierarchy } from './model-hierarchy.mjs';
import { modelFixture } from './model-fixtures.mjs';

const edit=(bytes,value)=>editModelHierarchy(bytes,{boneLimit:128,...value});
test('inspection owns its data and exposes actual skin, topology and rest fields',()=>{
  const bytes=modelFixture(),before=bytes.slice(),info=inspectModel(bytes);
  assert.deepEqual(info.bones.map(b=>[b.name,b.parent]),[['Root',-1],['Left',0],['Right',0]]);
  assert.equal(info.meshes[1].vertexCount,4);assert.deepEqual([...info.meshes[1].indices],[0,1,2,0,2,3]);
  assert.equal(info.meshes[1].joints[0],2);assert.equal(info.meshes[1].weights[0],1);assert.equal(info.attachments[0].bone,2);
  info.bones[0].matrix.fill(7);info.meshes[1].weights.fill(0);assert.deepEqual(bytes,before);
  assert.equal(inspectModel(bytes).meshes[1].weights[0],1);
});
test('reparent commands sort records and coherently remap parents/joints/selection',()=>{
  const bytes=modelFixture(),result=edit(bytes,{type:'reparent',bone:1,parent:2}),info=inspectModel(result.bytes);
  assert.deepEqual(info.bones.map(b=>[b.name,b.parent]),[['Root',-1],['Right',0],['Left',1]]);
  assert.deepEqual(result.oldToNew,[0,2,1]);assert.equal(info.meshes[0].joints[0],2);
  assert.equal(info.bones[2].matrix[12],-35,'Reparent must retain local bind transform');
  assert.throws(()=>edit(result.bytes,{type:'reparent',bone:1,parent:2}),/cycle/i);
});
test('rename, new TRS bones and explicit deletion are reversible resource bytes',()=>{
  const bytes=modelFixture(),named=edit(bytes,{type:'rename',bone:2,name:'Wing'});
  assert.equal(inspectModel(named.bytes).bones[2].name,'Wing');
  const created=edit(named.bytes,{type:'create',name:'Tip',parent:2,pose:[0,20,0,0,0,Math.PI/2,2,3,1]});
  const info=inspectModel(created.bytes);assert.equal(info.bones.length,4);assert.equal(info.bones[3].parent,2);
  assert(Math.abs(info.bones[3].matrix[1]-2)<1e-6);assert(Math.abs(info.bones[3].matrix[4]+3)<1e-6);
  assert.throws(()=>edit(created.bytes,{type:'delete',bone:2}),/replacement/i);
  const removed=inspectModel(edit(created.bytes,{type:'delete',bone:2,replacement:0}).bytes);
  assert.deepEqual(removed.bones.map(b=>[b.name,b.parent]),[['Root',-1],['Left',0],['Tip',0]]);
  assert.equal(removed.meshes[1].joints[0],0);assert.equal(removed.attachments[0].bone,0);
  assert.equal(inspectModel(bytes).bones[2].name,'Right');
});
test('invalid hierarchy commands leave caller data intact',()=>{
  const bytes=modelFixture(),before=bytes.slice();
  for(const command of [{type:'rename',bone:99,name:'No'},{type:'reparent',bone:0,parent:1},{type:'delete',bone:1,replacement:1},
    {type:'create',parent:3,name:'No',pose:[0,0,0,0,0,0,1,1,1]},{type:'rename',bone:1,name:'Bad\0name'},
    {type:'create',parent:0,name:'No',pose:[0,0,0,0,0,0,0,1,1]},{type:'unknown'}]){
    assert.throws(()=>edit(bytes,command));assert.deepEqual(bytes,before);
  }
});
