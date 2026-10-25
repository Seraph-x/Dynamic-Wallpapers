import test from 'node:test';
import assert from 'node:assert/strict';
import { bakeBoneDelta } from './model-fk.mjs';
import { modelFixture } from './model-fixtures.mjs';
import { readMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';
import { restMatrix } from './model-math.mjs';
import { mul } from './vendor/gltf-math.mjs';

const identity=[0,0,0,0,0,0,1,1,1];
const options={clip:7,bone:2,start:1,end:1,delta:identity};
const animations=doc=>doc.sections.find(s=>s.type==='MDLA').anims;
const animation=bytes=>animations(readMdlDoc(bytes))[0];
const change=fn=>{const doc=readMdlDoc(modelFixture());fn(doc,animations(doc)[0]);return writeMdlDoc(doc);};
const bake=(bytes,operation={})=>bakeBoneDelta(bytes,{...options,...operation});
const pose=(bytes,bone=2,frame=1)=>Array.from(animation(bytes).tracks[bone].data.subarray(frame*9,frame*9+9));
function rejects(bytes,operation,pattern){
 const before=new Uint8Array(bytes);
 assert.throws(()=>bake(bytes,operation),pattern);
 assert.deepEqual(new Uint8Array(bytes),before,'Rejected operations must retain their input');
}
function world(bytes,frame){
 const doc=readMdlDoc(bytes),bones=doc.sections.find(s=>s.type==='MDLS').bones,tracks=animations(doc)[0].tracks,result=[];
 for(const [i,bone] of bones.entries()){
  const local=restMatrix(Array.from(tracks[i].data.subarray(frame*9,frame*9+9)));
  result.push(bone.parent<0?local:Float32Array.from(mul(result[bone.parent],local)));
 }
 return result;
}

test('local delta adds translation and native Euler radians and multiplies signed scale',()=>{
 const bytes=change((d,a)=>a.tracks[2].data.set([35,30,3,.2,-.3,7,-2,3,4],9));
 const delta=[2,-5,7,.4,.5,8,-3,.5,2],source=pose(bytes),expected=source.map((v,i)=>Math.fround(i<6?v+Math.fround(delta[i]):v*Math.fround(delta[i])));
 const result=bake(bytes,{delta});
 assert(result instanceof Uint8Array);assert.deepEqual(pose(result),expected);
 assert(pose(result)[5]>2*Math.PI,'Euler addition must not wrap to a shortest arc');
});
test('native Float32 delta quantization happens before addition',()=>{
 const bytes=change((d,a)=>a.tracks[2].data[9]=1),delta=identity.slice();delta[0]=2**-24+2**-50;
 assert.equal(Math.fround(1+delta[0]),1+2**-23);
 assert.equal(pose(bake(bytes,{delta}))[0],1);
 assert.equal(delta[0],2**-24+2**-50,'Caller delta must remain unchanged');
});
test('inclusive single, first, terminal and full ranges preserve every unrelated byte',()=>{
 for(const [start,end] of [[0,0],[1,1],[2,2],[0,2]]){
  const bytes=change((doc,a)=>{
   a.tracks[2].boneId=123;a.unk1=71;
   animations(doc).push({...structuredClone(a),id:19,name:'Untouched'});
   doc.sections.push({type:'MDLE',version:'0002',b8:0,data:Uint8Array.from({length:3*64},(_,i)=>(i*17)%256),tail:new Uint8Array()});
  }),before=bytes.slice(),expected=readMdlDoc(bytes);
  for(let f=start;f<=end;f++)animations(expected)[0].tracks[2].data[f*9+1]-=4;
  const result=bake(bytes,{start,end,delta:[0,-4,0,0,0,0,1,1,1]});
  assert.deepEqual(result,writeMdlDoc(expected));assert.deepEqual(bytes,before);
 }
});
test('parent translation rotation and scale move descendants while preserving child local tracks and binds',()=>{
 const bytes=modelFixture(),result=bake(bytes,{bone:0,delta:[10,20,0,0,0,Math.PI/2,2,3,1]});
 const childWorld=world(result,1),source=readMdlDoc(bytes),edited=readMdlDoc(result);
 for(const bone of [1,2])assert.deepEqual(animations(edited)[0].tracks[bone],animations(source)[0].tracks[bone]);
 assert.deepEqual(edited.sections.find(s=>s.type==='MDLS'),source.sections.find(s=>s.type==='MDLS'));
 for(const [bone,x,y] of [[1,10,-50],[2,-80,90]]){
  assert(Math.abs(childWorld[bone][12]-x)<1e-4);assert(Math.abs(childWorld[bone][13]-y)<1e-4);
 }
 assert.deepEqual(world(result,0),world(bytes,0));assert.deepEqual(world(result,2),world(bytes,2));
});
test('a transformed parent does not turn a child local translation into a world-space edit',()=>{
 const bytes=change((d,a)=>a.tracks[0].data.set([10,20,0,0,0,Math.PI/2,2,3,1],9));
 const before=world(bytes,1),result=bake(bytes,{delta:[4,0,0,0,0,0,1,1,1]}),after=world(result,1);
 assert.equal(pose(result)[0],39);assert(Math.abs(after[2][12]-before[2][12])<1e-4);
 assert(Math.abs(after[2][13]-before[2][13]-8)<1e-4);
 assert.deepEqual(after[1],before[1]);
});
test('sequential edits compose against committed samples and retain earlier edits outside the next range',()=>{
 const first=bake(modelFixture(),{start:0,end:1,delta:[1,2,3,.1,.2,.3,2,3,4]}),second=bake(first,{start:1,end:2,delta:[-2,4,0,0,0,.2,.5,-1,1]});
 assert.deepEqual(pose(second,2,0),pose(first,2,0));
 assert.deepEqual(pose(second),pose(first).map((v,i)=>Math.fround(i<6?v+Math.fround([-2,4,0,0,0,.2][i]):v*[.5,-1,1][i-6])));
 assert.deepEqual(pose(second,2,2),[33,64,0,0,0,Math.fround(.2),.5,-1,1]);
});
test('identity delta is byte exact and returns owned bytes for Buffer and Uint8Array including negative zero',()=>{
 for(const source of [modelFixture(),Buffer.from(modelFixture())]){
  const bytes=change((d,a)=>{a.tracks[2].data[9]=-0;a.tracks[2].data[12]=-0;a.tracks[2].data[14]=Math.fround(.7312345);});
  source.set(bytes);const before=new Uint8Array(source),result=bake(source,{start:0,end:2});
  assert.deepEqual(new Uint8Array(result),before);result[0]=0;assert.deepEqual(new Uint8Array(source),before);
 }
});
test('loop terminal-only bake changes the terminal pose and leaves sample zero exact',()=>{
 const bytes=change((d,a)=>{a.mode='loop';a.tracks[2].data[1]=4;a.tracks[2].data[19]=99;});
 const result=bake(bytes,{start:2,end:2,delta:[0,7,0,0,0,0,1,1,1]});
 assert.deepEqual(pose(result,2,0),pose(bytes,2,0));assert.equal(pose(result,2,2)[1],106);
 assert.deepEqual(pose(result,2,1),pose(bytes,2,1));
});
test('reject malformed clip bone and inclusive sample selectors without mutation',()=>{
 for(const operation of [{clip:'7'},{clip:null},{clip:-1},{clip:2**32},{clip:8},{clip:NaN},{bone:-1},{bone:3},{bone:1.1},{bone:'2'},
  {start:-1},{start:1.1},{start:'1'},{start:NaN},{start:2,end:1},{end:3},{end:Infinity},{end:null}])rejects(modelFixture(),operation,/clip|bone|frame|range/i);
 for(const operation of [undefined,null,[],7,'delta'])assert.throws(()=>bakeBoneDelta(modelFixture(),operation),/operation|options/i);
});
test('reject malformed delta and explicit Float32 overflow and underflow',()=>{
 for(const delta of [null,[],new Float32Array(identity),Array(9),[...identity,1]])rejects(modelFixture(),{delta},/delta|nine|component/i);
 for(const value of [NaN,Infinity,-Infinity,'1',undefined,1e40,-1e40,1e-50,-1e-50])for(const component of [0,3,6]){
  const delta=identity.slice();delta[component]=value;rejects(modelFixture(),{delta},/delta|finite|Float32|component/i);
 }
});
test('reject result overflow and multiplication underflow before writing Float32 samples',()=>{
 for(const component of [0,3,6]){
  const bytes=change((d,a)=>a.tracks[2].data[9+component]=3e38),delta=identity.slice();delta[component]=component<6?3e38:2;
  rejects(bytes,{delta},/overflow|Float32|finite/i);
 }
 const bytes=change((d,a)=>a.tracks[2].data[15]=1e-30);
 rejects(bytes,{delta:[0,0,0,0,0,0,1e-20,1,1]},/underflow|Float32/i);
});
test('zero and singular scales reject visibly while signed scale remains supported',()=>{
 for(const scale of [0,1e-20])rejects(modelFixture(),{delta:[0,0,0,0,0,0,scale,1,1]},/invert|singular|matrix/i);
 assert.deepEqual(pose(bake(modelFixture(),{delta:[0,0,0,0,0,0,-2,-3,-4]})).slice(6),[-2,-3,-4]);
});
test('sampled descendant world overflow and singular inverse fail before publication',()=>{
 const overflow=change((d,a)=>a.tracks[2].data[15]=1e20);
 rejects(overflow,{bone:0,delta:[0,0,0,0,0,0,1e20,1,1]},/overflow|Float32|finite/i);
 const singular=change((d,a)=>a.tracks[2].data[17]=1e-6);
 rejects(singular,{bone:0,delta:[0,0,0,0,0,0,1,1,1e-7]},/inverse|invert|singular/i);
});
test('skin matrix and animated vertex Float32 overflows fail visibly',()=>{
 const skin=change(d=>d.sections.find(s=>s.type==='MDLS').bones[0].matrix=restMatrix([0,0,0,0,0,0,1e-8,1e8,1]));
 rejects(skin,{bone:0,delta:[0,0,0,0,0,0,1e32,1,1]},/skin|overflow|Float32/i);
 rejects(modelFixture(),{bone:0,delta:[0,0,0,0,0,0,2e37,1,1]},/vertex|overflow|Float32/i);
});
test('unsupported source layout and malformed tracks fail without altering input',()=>{
 rejects(change(d=>d.trailing=Uint8Array.of(1)),{},/Unsupported/i);
 rejects(change((d,a)=>a.tracks[2].data=a.tracks[2].data.slice(0,9)),{},/Unsupported/i);
 rejects(change((d,a)=>a.tracks[2].data[9]=NaN),{},/Unsupported/i);
 for(const bytes of [null,[],new Uint8Array(3)])assert.throws(()=>bake(bytes));
});
