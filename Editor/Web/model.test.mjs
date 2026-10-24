import test from 'node:test';
import assert from 'node:assert/strict';
import { readMdlDoc, writeMdlDoc } from './vendor/mdl-codec.mjs';
import { modelFixture, translation } from './model-fixtures.mjs';
import { rewriteSkeleton as rewrite, setSkinInfluences as influences } from './model.mjs';
import { restPose } from './model-math.mjs';
import { readFile } from 'node:fs/promises';

const section=(doc,type)=>doc.sections.find(s=>s.type===type);
const identity=()=>[0,1,2].map(source=>({source,parent:source===0?-1:0}));
const swapped=()=>[{source:0,parent:-1},{source:2,parent:0},{source:1,parent:0}];
const rewriteSkeleton=(bytes,options)=>rewrite(bytes,{boneLimit:128,...options});
const setSkinInfluences=(bytes,options)=>influences(bytes,{boneLimit:128,...options});
function modify(operation) {const doc=readMdlDoc(modelFixture());operation(doc);return writeMdlDoc(doc);}
function joint(doc,mesh=0,vertex=0) {const m=doc.meshes[mesh],stride=80;return new DataView(m.vertexData.buffer,m.vertexData.byteOffset,m.vertexData.byteLength).getUint32(vertex*stride+40,true);}
test('vendored codec round trips authored fixtures byte for byte',()=>{
  const bytes=modelFixture();assert.deepEqual(writeMdlDoc(readMdlDoc(bytes)),bytes);
});
test('sibling reindexing preserves tracks, metadata, events, weights and attachment ownership',()=>{
  const bytes=modelFixture(),before=bytes.slice(),original=readMdlDoc(bytes);
  const result=rewriteSkeleton(bytes,{bones:swapped()}),doc=readMdlDoc(result.bytes);
  assert.deepEqual(result.oldToNew,[0,2,1]);assert.deepEqual(bytes,before);
  assert.deepEqual(section(doc,'MDLS').bones,[section(original,'MDLS').bones[0],section(original,'MDLS').bones[2],section(original,'MDLS').bones[1]]);
  assert.equal(joint(doc),2);assert.equal(joint(doc,1),1);
  assert.deepEqual(section(doc,'MDLA').anims[0].tracks,[0,2,1].map(i=>section(original,'MDLA').anims[0].tracks[i]));
  assert.deepEqual(section(doc,'MDLA').anims[0].events,section(original,'MDLA').anims[0].events);
  assert.equal(section(doc,'MDAT').attachments[0].bone,1);
  assert.deepEqual(section(doc,'MDAT').attachments[0].matrix,section(original,'MDAT').attachments[0].matrix);
});
test('deletion requires explicit replacement for weighted joints and attachments',()=>{
  const bytes=modelFixture(),bones=[{source:0,parent:-1},{source:1,parent:0}];
  assert.throws(()=>rewriteSkeleton(bytes,{bones}),/replacement/i);
  const result=rewriteSkeleton(bytes,{bones,replacements:{2:1}}),doc=readMdlDoc(result.bytes);
  assert.deepEqual(result.oldToNew,[0,1,-1]);assert.equal(joint(doc,1),1);assert.equal(section(doc,'MDAT').attachments[0].bone,1);
  assert.equal(section(doc,'MDLA').anims[0].tracks.length,2);assert.equal(section(doc,'MDLS').tail.length,14+84*2);
});
test('new bones gain constant rest tracks while all existing samples survive',()=>{
  const bytes=modelFixture(),bones=[...identity(),{source:null,parent:2,name:'Tip',matrix:translation(0,20)}];
  const doc=readMdlDoc(rewriteSkeleton(bytes,{bones}).bytes),original=readMdlDoc(bytes);
  assert.deepEqual(section(doc,'MDLA').anims[0].tracks.slice(0,3),section(original,'MDLA').anims[0].tracks);
  assert.deepEqual([...section(doc,'MDLA').anims[0].tracks[3].data],Array(3).fill([0,20,0,0,0,0,1,1,1]).flat());
  assert.equal(section(doc,'MDLS').tail.length,14+84*4);
});
test('invalid topology, input and unresolved references never mutate source bytes',()=>{
  const bytes=modelFixture(),before=bytes.slice();
  for(const bones of [[],[{source:0,parent:1},{source:1,parent:0}], [{source:0,parent:-1},{source:0,parent:0}],
    [{source:3,parent:-1}], [...identity(),{source:null,parent:0,name:'Broken',matrix:translation().fill(0)}],
    [{source:0,parent:-1,name:'bad\0name'},...identity().slice(1)]]) assert.throws(()=>rewriteSkeleton(bytes,{bones}));
  assert.throws(()=>rewriteSkeleton(bytes,{bones:identity(),replacements:{2:99}}));
  for(const length of [0,8,20,bytes.length-5])assert.throws(()=>rewriteSkeleton(bytes.slice(0,length),{bones:swapped()}));
  assert.deepEqual(bytes,before);
  const padded=new Uint8Array(bytes.length+20);padded.set(bytes,7);
  assert.deepEqual(rewriteSkeleton(padded.subarray(7,7+bytes.length),{bones:swapped()}).bytes,rewriteSkeleton(bytes,{bones:swapped()}).bytes);
});
test('unknown bone-dependent data stays byte exact on rename and blocks structural edits',()=>{
  const variants=[
    doc=>section(doc,'MDLS').tail[0]=42,
    doc=>section(doc,'MDLS').tail=new Uint8Array([5,7,9]),
    doc=>section(doc,'MDLA').anims[0].prefix[0]=1,
    doc=>section(doc,'MDLA').anims[0].tracks.pop(),
    doc=>section(doc,'MDLA').version='0007',
    doc=>section(doc,'MDAT').tail=new Uint8Array([1]),
    doc=>doc.sections.push({type:'MDLE',version:'0002',b8:0,data:new Uint8Array(64*3),tail:new Uint8Array([9])}),
  ];
  for(const change of variants){
    const bytes=modify(change),doc=readMdlDoc(bytes),names=identity();names[1].name='Renamed';
    const renamed=readMdlDoc(rewriteSkeleton(bytes,{bones:names}).bytes);section(doc,'MDLS').bones[1].name='Renamed';
    assert.deepEqual(renamed,doc);assert.throws(()=>rewriteSkeleton(bytes,{bones:swapped()}),/unsupported|track|layout|tail|section/i);
  }
});
test('dense MDLE tables and nonidentity permutation values follow the bone map',()=>{
  const bytes=modify(doc=>{
    const tail=section(doc,'MDLS').tail,dv=new DataView(tail.buffer);const at=12+76*3+1;
    [1,2,0].forEach((v,i)=>dv.setUint32(at+i*4,v,true));
    const data=new Uint8Array(64*3),view=new DataView(data.buffer);
    [10,20,30].forEach((x,i)=>translation(x).forEach((v,k)=>view.setFloat32(i*64+k*4,v,true)));
    doc.sections.push({type:'MDLE',version:'0002',b8:0,data,tail:new Uint8Array(0)});
  });
  const doc=readMdlDoc(rewriteSkeleton(bytes,{bones:swapped()}).bytes),dv=new DataView(section(doc,'MDLE').data.buffer);
  assert.deepEqual([0,1,2].map(i=>dv.getFloat32(i*64+48,true)),[10,30,20]);
  const tail=section(doc,'MDLS').tail,view=new DataView(tail.buffer),at=12+76*3+1;
  assert.deepEqual([0,1,2].map(i=>view.getUint32(at+i*4,true)),[2,0,1]);
  assert.throws(()=>rewriteSkeleton(bytes,{bones:identity().slice(0,2),replacements:{2:1}}),/permutation/i);
});
test('numeric influences normalize only edited vertices and leave unknown sections intact',()=>{
  const bytes=modelFixture(),before=readMdlDoc(bytes);
  const result=setSkinInfluences(bytes,{mesh:1,edits:[{vertex:1,influences:[{joint:1,weight:3},{joint:2,weight:1}]}]}),doc=readMdlDoc(result);
  assert.deepEqual(doc.sections,before.sections);assert.deepEqual(doc.meshes[0],before.meshes[0]);
  const m=doc.meshes[1],v=new DataView(m.vertexData.buffer),stride=80;
  assert.equal(v.getUint32(stride+40,true),1);assert.equal(v.getUint32(stride+44,true),2);
  assert.equal(v.getFloat32(stride+56,true),.75);assert.equal(v.getFloat32(stride+60,true),.25);
  assert.deepEqual(m.vertexData.slice(0,stride),before.meshes[1].vertexData.slice(0,stride));
  assert.deepEqual(m.vertexData.slice(stride*2),before.meshes[1].vertexData.slice(stride*2));
});
test('invalid influence edits reject with original bytes unchanged',()=>{
  const bytes=modelFixture(),before=bytes.slice();
  for(const edits of [[{vertex:0,influences:[]}],[{vertex:99,influences:[{joint:1,weight:1}]}],
    [{vertex:0,influences:[{joint:3,weight:1}]}],[{vertex:0,influences:[{joint:1,weight:NaN}]}],
    [{vertex:0,influences:[{joint:1,weight:0}]}],[{vertex:0,influences:[{joint:1,weight:-1}]}],
    [{vertex:0,influences:[{joint:1,weight:1},{joint:1,weight:1}]}],
    [{vertex:0,influences:[{joint:1,weight:1}]},{vertex:0,influences:[{joint:2,weight:1}]}]]) {
    assert.throws(()=>setSkinInfluences(bytes,{mesh:0,edits}));assert.deepEqual(bytes,before);
  }
});
test('new rest transforms must remain invertible after native Float32 encoding',()=>{
  const tiny=Array.from(translation());tiny[0]=1e-46;
  assert.throws(()=>rewriteSkeleton(modelFixture(),{bones:[...identity(),{source:null,parent:0,name:'Tiny',matrix:tiny}]}),/invertible|float32/i);
  const shear=translation();shear[4]=.2;
  assert.throws(()=>rewriteSkeleton(modelFixture(),{bones:[...identity(),{source:null,parent:0,name:'Shear',matrix:shear}]}),/shear/i);
  const overflow=Array.from(translation());overflow[12]=1e40;
  assert.throws(()=>rewriteSkeleton(modelFixture(),{bones:[...identity(),{source:null,parent:0,name:'Overflow',matrix:overflow}]}),/finite|float32/i);
});
test('authored skeletons cannot exceed the pinned renderer bone limit',()=>{
  const bones=[...identity(),...Array.from({length:1022},(_,i)=>({source:null,parent:0,name:`Bone ${i}`,matrix:translation()}))];
  assert.throws(()=>rewriteSkeleton(modelFixture(),{bones}),/1024|bone limit/i);
});
test('TRS decomposition preserves rotated, reflected and gimbal-lock rest samples',()=>{
  const cases=[
    [[0,2,0,0,-3,0,0,0,0,0,4,0,7,8,9,1],[7,8,9,0,0,Math.PI/2,2,3,4]],
    [[0,0,-2,0,0,3,0,0,4,0,0,0,7,8,9,1],[7,8,9,0,Math.PI/2,0,2,3,4]],
    [[0,0,2,0,0,3,0,0,-4,0,0,0,7,8,9,1],[7,8,9,0,-Math.PI/2,0,2,3,4]],
    [[-2,0,0,0,0,3,0,0,0,0,4,0,7,8,9,1],[7,8,9,0,0,0,-2,3,4]],
  ];
  for(const [matrix,expected] of cases)restPose(matrix).forEach((v,i)=>assert(Math.abs(v-expected[i])<1e-6,`TRS component ${i}`));
});
test('header-looking animation trailer bytes cannot be treated as editable tracks',()=>{
  const bytes=modify(doc=>{
    const anim=section(doc,'MDLA').anims[0];
    const prefix=new Uint8Array(31),dv=new DataView(prefix.buffer);dv.setUint32(0,42,true);
    prefix.set(new TextEncoder().encode('X\0loop\0'),8);dv.setFloat32(15,2,true);dv.setUint32(19,2,true);dv.setUint32(27,3,true);
    anim.prefix=prefix;section(doc,'MDLA').anims.push(structuredClone({...anim,id:8,name:'Second',prefix:new Uint8Array(31)}));
  });
  assert(readMdlDoc(bytes).sections.find(s=>s.type==='MDLA').raw,'Fixture must exercise the ambiguous boundary parser');
  const rename=identity();rename[1].name='Safe rename';const doc=readMdlDoc(rewriteSkeleton(bytes,{bones:rename}).bytes);
  assert.deepEqual(section(doc,'MDLA').raw,section(readMdlDoc(bytes),'MDLA').raw);
  assert.throws(()=>rewriteSkeleton(bytes,{bones:swapped()}),/section/i);
});
test('independent byte fixture follows the declared joint, track and attachment map',async()=>{
  const bytes=new Uint8Array(await readFile(new URL('../../Tests/Fixtures/EditorSkeleton/three-bone.mdl',import.meta.url)));
  assert.deepEqual(writeMdlDoc(readMdlDoc(bytes)),bytes);
  const doc=readMdlDoc(rewriteSkeleton(bytes,{bones:swapped()}).bytes),mesh=doc.meshes[0],dv=new DataView(mesh.vertexData.buffer);
  assert.deepEqual([0,1,2].map(i=>dv.getUint32(i*52+12,true)),[0,2,1]);
  assert.equal(section(doc,'MDAT').attachments[0].bone,1);
  assert.deepEqual(section(doc,'MDLA').anims[0].tracks.map(t=>t.data[9]),[0,50,-25]);
  assert.equal(section(doc,'MDLS').bones[1].name,'Right');
});
test('structural and weight edits require a verified target GPU bone capacity',()=>{
  const bytes=modelFixture(),edits=[{vertex:0,influences:[{joint:1,weight:1}]}];
  for(const boneLimit of [undefined,0,129,2,NaN,2.5]){
    assert.throws(()=>rewrite(bytes,{bones:swapped(),boneLimit}),/bone.*(capacity|limit)|capacity/i);
    assert.throws(()=>influences(bytes,{mesh:0,edits,boneLimit}),/bone.*(capacity|limit)|capacity/i);
  }
  assert.doesNotThrow(()=>rewrite(bytes,{bones:identity()}),'Rename/no-op must not require a new rendering capability');
  assert.doesNotThrow(()=>rewrite(bytes,{bones:swapped(),boneLimit:3}));
});
