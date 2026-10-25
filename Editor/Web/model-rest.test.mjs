import test from 'node:test';
import assert from 'node:assert/strict';
import * as model from './model.mjs';
import { editModelHierarchy } from './model-hierarchy.mjs';
import { restPose,restMatrix } from './model-math.mjs';
import { modelFixture,translation } from './model-fixtures.mjs';
import { readMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';
const section=(doc,type)=>doc.sections.find(s=>s.type===type);
const edit=(bytes,options)=>model.setBoneRestTransform(bytes,{bone:2,pose:[45,0,0,0,0,0,1,1,1],boneLimit:3,...options});
const modify=fn=>{const doc=readMdlDoc(modelFixture());fn(doc);return writeMdlDoc(doc);};
const pose=x=>[x,0,0,0,0,0,1,1,1];
test('rest transaction changes only selected bind matrix and preserves actual authored data',()=>{
  assert.equal(typeof model.setBoneRestTransform,'function','Missing bone rest transaction');
  const bytes=modelFixture(),before=bytes.slice(),expected=readMdlDoc(bytes);
  const result=edit(bytes);section(expected,'MDLS').bones[2].matrix=translation(45);
  assert.deepEqual(readMdlDoc(result),expected);assert.deepEqual(bytes,before);
  const parent=edit(bytes,{bone:0,pose:pose(12)});section(expected,'MDLS').bones[2].matrix=translation(35);section(expected,'MDLS').bones[0].matrix=translation(12);
  assert.deepEqual(readMdlDoc(parent),expected,'A bind change must not rewrite descendant local poses or absolute tracks');
});
test('rest edit preserves distinct static tails, dense MDLE, metadata and unknown animation bytes',()=>{
  for(const variant of [doc=>section(doc,'MDLS').tail=new Uint8Array(0),doc=>section(doc,'MDLS').tail[0]=42,
    doc=>section(doc,'MDLA').anims[0].prefix[0]=17,doc=>{
      const data=new Uint8Array(3*64),view=new DataView(data.buffer);for(let i=0;i<3;i++)translation(i*50).forEach((v,k)=>view.setFloat32(i*64+k*4,v,true));
      doc.sections.push({type:'MDLE',version:'0002',b8:0,data,tail:new Uint8Array([9,7])});
    }]){
    const bytes=modify(variant),expected=readMdlDoc(bytes);section(expected,'MDLS').bones[2].matrix=translation(45);
    assert.deepEqual(readMdlDoc(edit(bytes)),expected);
  }
});
test('unchanged canonical TRS preserves exact matrices and bytes without recomposition drift',()=>{
  for(const values of [[7,8,9,.37,-.21,.49,2,3,4],[7,8,9,0,Math.PI/2,0,2,3,4],[7,8,9,0,0,0,-2,3,4]]){
    const bytes=modify(doc=>section(doc,'MDLS').bones[2].matrix=restMatrix(values));
    const canonical=Array.from(restPose(section(readMdlDoc(bytes),'MDLS').bones[2].matrix));
    assert.deepEqual(edit(bytes,{pose:canonical}),bytes);
    const padded=new Uint8Array(bytes.length+12);padded.set(bytes,7);
    assert.deepEqual(edit(padded.subarray(7,7+bytes.length),{pose:canonical}),bytes);
  }
});
test('translation rotation and reflected scale use actual local column-major matrix layout',()=>{
  const bytes=edit(modelFixture(),{pose:[7,8,9,0,0,Math.PI/2,2,3,4]});
  const actual=section(readMdlDoc(bytes),'MDLS').bones[2].matrix;
  const expected=[0,2,0,0,-3,0,0,0,0,0,4,0,7,8,9,1];actual.forEach((v,i)=>assert(Math.abs(v-expected[i])<1e-6));
  const reflected=edit(modelFixture(),{pose:[0,0,0,0,0,0,-2,3,4]});assert.equal(section(readMdlDoc(reflected),'MDLS').bones[2].matrix[0],-2);
});
test('invalid rest input never changes source bytes',()=>{
  const bytes=modelFixture(),before=bytes.slice();
  for(const options of [{bone:-1},{bone:3},{bone:1.5},{boneLimit:undefined},{boneLimit:2},{boneLimit:129},
    {pose:undefined},{pose:[]},{pose:[0,0,0,0,0,0,0,1,1]},{pose:[0,0,0,0,0,0,1e-46,1,1]},
    {pose:[1e40,0,0,0,0,0,1,1,1]},{pose:[0,0,0,NaN,0,0,1,1,1]}])assert.throws(()=>edit(bytes,options));
  for(const length of [0,8,bytes.length-5])assert.throws(()=>edit(bytes.slice(0,length)));
  const cycle=modify(doc=>section(doc,'MDLS').bones[1].parent=2);assert.throws(()=>edit(cycle),/parent|hierarchy/i);
  assert.deepEqual(bytes,before);
});
test('rest validation rejects renderer inverse fallback, composed overflow and descendant singularity',()=>{
  const bytes=modelFixture();assert.throws(()=>edit(bytes,{pose:[0,0,0,0,0,0,1,1,1e-13]}),/inverse|invertible|pivot/i);
  const smallParent=modify(doc=>section(doc,'MDLS').bones[0].matrix=restMatrix([0,0,0,0,0,0,1,1,1e-7]));
  assert.throws(()=>edit(smallParent,{pose:[0,0,0,0,0,0,1,1,1e-6]}),/inverse|invertible|pivot/i);
  const largeChild=modify(doc=>section(doc,'MDLS').bones[1].matrix=restMatrix([0,0,0,0,0,0,1e20,1,1]));
  assert.throws(()=>edit(largeChild,{bone:0,pose:[0,0,0,0,0,0,1e30,1,1]}),/finite|float32|overflow/i);
  assert.throws(()=>edit(bytes,{pose:[1e38,0,0,0,0,0,1e-8,1,1]}),/inverse|finite|float32/i);
});
test('ordinary nonsingular world shear from valid local TRS is supported',()=>{
  const bytes=modify(doc=>section(doc,'MDLS').bones[0].matrix=restMatrix([1,2,3,0,0,0,2,3,4]));
  assert.doesNotThrow(()=>edit(bytes,{pose:[45,0,0,.2,.3,.7,1,2,1]}));
});
test('a representable matrix edit is not discarded by quantizing Euler input to Float32',()=>{
  const bytes=modify(doc=>section(doc,'MDLS').bones[2].matrix=restMatrix([0,0,0,.37,-.21,.49,2,3,4]));
  const canonical=Array.from(restPose(section(readMdlDoc(bytes),'MDLS').bones[2].matrix)),changed=canonical.slice();changed[3]+=1e-8;
  assert.equal(Math.fround(changed[3]),canonical[3]);
  assert.notDeepEqual(edit(bytes,{pose:changed}),bytes,'Representable matrix update was silently rounded away');
});

test('a combined rest and reparent edit validates the final descendant world bind',()=>{
  const bytes=modify(doc=>section(doc,'MDLS').bones[1].matrix=restMatrix([0,0,0,0,0,0,1,1,1e-7]));
  const rest=edit(bytes,{pose:[35,0,0,0,0,0,1,1,1e-6]});
  assert.throws(()=>editModelHierarchy(rest,{type:'reparent',bone:2,parent:1,boneLimit:3}),/inverse|invertible/i);
});
test('a combined rest and parent correction validates only the final candidate',()=>{
  const bytes=modify(doc=>{const b=section(doc,'MDLS').bones;b[1].matrix=restMatrix([0,0,0,0,0,0,1,1,1e-7]);b[2].parent=1;b[2].matrix=restMatrix([35,0,0,0,0,0,1,1,1e-4]);});
  const before=bytes.slice(),pose=[35,0,0,0,0,0,1,1,1e-6];
  const result=editModelHierarchy(bytes,{type:'update',bone:2,parent:0,name:'Repaired',pose,boneLimit:3});
  const bone=section(readMdlDoc(result.bytes),'MDLS').bones[2];assert.equal(bone.parent,0);assert.equal(bone.name,'Repaired');assert(Math.abs(bone.matrix[10]-1e-6)<1e-12);assert.deepEqual(bytes,before);
  assert.throws(()=>editModelHierarchy(modelFixture(),{type:'update',bone:2,parent:2,pose,boneLimit:3}),/cycle/i);
});
