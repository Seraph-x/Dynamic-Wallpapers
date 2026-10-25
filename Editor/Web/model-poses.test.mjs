import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectBonePose,editBonePose } from './model-poses.mjs';
import { modelFixture } from './model-fixtures.mjs';
import { readMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';
import { editModelClips } from './model-clips.mjs';
import { restMatrix } from './model-math.mjs';
const target={clip:7,bone:2,frame:1};
const anim=bytes=>readMdlDoc(bytes).sections.find(s=>s.type==='MDLA').anims[0];
const change=fn=>{const doc=readMdlDoc(modelFixture());fn(doc,doc.sections.find(s=>s.type==='MDLA').anims[0]);return writeMdlDoc(doc);};
const edit=(bytes,options)=>editBonePose(bytes,{...target,...options});
function rejects(bytes,options,pattern){const before=new Uint8Array(bytes);assert.throws(()=>edit(bytes,options),pattern);assert.deepEqual(new Uint8Array(bytes),before);}

test('inspection exposes exact native local pose, frame time and owned values',()=>{
 const bytes=modelFixture(),before=bytes.slice(),value=inspectBonePose(bytes,target);
 assert.deepEqual(value,{clip:7,bone:2,frame:1,fps:2,frameCount:2,time:.5,pose:[35,30,0,0,0,0,1,1,1]});
 value.pose[0]=999;assert.equal(inspectBonePose(bytes,target).pose[0],35);assert.deepEqual(bytes,before);
});
test('one pose edit retains every unrelated sample, clip, event and binary section',()=>{
 const bytes=editModelClips(modelFixture(),{type:'duplicate',id:7,name:'Untouched'}).bytes,before=readMdlDoc(bytes),pose=[35,12,0,0,0,Math.fround(.4),1,2,1];
 const result=edit(bytes,{type:'set',pose}),expected=readMdlDoc(bytes);expected.sections.find(s=>s.type==='MDLA').anims[0].tracks[2].data.set(pose,9);
 assert.deepEqual(readMdlDoc(result),expected);assert.deepEqual(readMdlDoc(bytes),before);assert.deepEqual(result,writeMdlDoc(expected));
});
test('Float32 canonical no-op remains byte exact including radians',()=>{
 const bytes=change((d,a)=>{a.tracks[2].data[14]=Math.fround(.7312345);});
 assert.deepEqual(edit(bytes,{type:'set',pose:inspectBonePose(bytes,target).pose}),bytes);
});
test('reset uses actual local bind transforms instead of animation frame zero',()=>{
 const bytes=change((d,a)=>{d.sections.find(s=>s.type==='MDLS').bones[2].matrix=restMatrix([35,13,0,0,0,.4,1,1,1]);a.tracks[2].data[1]=88;});
 const result=edit(bytes,{type:'reset'}),pose=inspectBonePose(result,target).pose;
 assert.equal(pose[1],13);assert(Math.abs(pose[5]-.4)<1e-6);assert.deepEqual(anim(result).tracks[2].data.subarray(0,9),anim(bytes).tracks[2].data.subarray(0,9));
});
test('range baking preserves endpoints and all unrelated bones and metadata',()=>{
 let bytes=editModelClips(modelFixture(),{type:'update',id:7,frameCount:4}).bytes;
 bytes=edit(bytes,{type:'set',frame:0,pose:[35,4,0,0,0,0,1,1,1]});
 bytes=edit(bytes,{type:'set',frame:4,pose:[35,44,0,0,0,0,1,1,1]});
 const result=edit(bytes,{type:'interpolate',start:0,end:4}),expected=readMdlDoc(bytes),track=expected.sections.find(s=>s.type==='MDLA').anims[0].tracks[2].data;
 for(let f=1;f<4;f++)track[f*9+1]=4+10*f;
 assert.deepEqual(readMdlDoc(result),expected);
});
test('Euler baking follows pinned single-wrap interpolation including multiple turns',()=>{
 for(const [start,end] of [[3,-3],[0,Math.fround(4*Math.PI)]]){
  const bytes=change((d,a)=>{a.tracks[2].data[5]=start;a.tracks[2].data[23]=end;});
  const actual=inspectBonePose(edit(bytes,{type:'interpolate',start:0,end:2}),target).pose[5];
  let delta=end-start;if(delta>Math.PI)delta-=2*Math.PI;else if(delta< -Math.PI)delta+=2*Math.PI;
  assert.equal(actual,Math.fround(start+delta/2));
 }
});
test('range editing affects only interiors of the chosen subrange',()=>{
 const bytes=editModelClips(modelFixture(),{type:'update',id:7,frameCount:6}).bytes;
 const result=edit(bytes,{type:'interpolate',start:2,end:4}),a=anim(bytes).tracks[2].data,b=anim(result).tracks[2].data;
 assert.deepEqual(b.subarray(0,27),a.subarray(0,27));assert.deepEqual(b.subarray(36),a.subarray(36));
});
test('reject invalid clip, bone and frame indices without mutating bytes',()=>{
 for(const options of [{clip:8},{clip:'7'},{clip:-1},{bone:-1},{bone:3},{bone:1.1},{frame:-1},{frame:3},{frame:NaN},{frame:'1'}])rejects(modelFixture(),{type:'reset',...options},/clip|bone|frame/i);
});
test('reject nonfinite, unrepresentable and singular local poses',()=>{
 for(const pose of [null,[],[35,30,0,0,0,0,1,1,NaN],[35,30,0,0,0,0,1,1,0],[35,30,0,0,0,0,1,1,1e-50],[1e40,30,0,0,0,0,1,1,1],['35',30,0,0,0,0,1,1,1]])rejects(modelFixture(),{type:'set',pose});
});
test('an explicit nonzero position or rotation cannot silently underflow to zero',()=>{
 for(const component of [0,3]){const pose=[35,30,0,0,0,0,1,1,1];pose[component]=1e-50;rejects(modelFixture(),{type:'set',pose},/Float32|underflow/i);}
});
test('reject invalid or adjacent interpolation endpoints rather than claiming a bake',()=>{
 for(const options of [{start:0,end:1},{start:2,end:0},{start:-1,end:2},{start:0,end:3},{start:.1,end:2},{start:'0',end:2}])rejects(modelFixture(),{type:'interpolate',...options},/frame|range|interior/i);
});
test('interpolation rejects singular intermediate scales instead of replacing geometry',()=>{
 const bytes=change((d,a)=>{a.tracks[2].data[6]=1;a.tracks[2].data[24]=-1;});rejects(bytes,{type:'interpolate',start:0,end:2},/invert|singular|matrix/i);
});
test('sampled parent/world Float32 overflow is visible before publication',()=>{
 const bytes=change((d,a)=>{for(const bone of [0,2])a.tracks[bone].data[15]=1e20;});
 rejects(bytes,{type:'set',pose:[35,30,0,0,0,0,1e20,1,1]},/overflow|finite|Float32/i);
});
test('unsupported layout and operations fail without mutating Buffer or Uint8Array',()=>{
 const bytes=change(d=>{d.trailing=Uint8Array.of(1);});rejects(bytes,{type:'reset'},/Unsupported/i);
 for(const source of [modelFixture(),Buffer.from(modelFixture())])rejects(source,{type:'unknown'});
});
