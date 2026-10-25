import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectIkChain,solveTwoBoneIk,bakeTwoBoneIk } from './model-ik.mjs';
import { ikFixture } from './model-ik-fixture.mjs';
import { readMdlDoc,writeMdlDoc,mdlsTail } from './vendor/mdl-codec.mjs';
import { restMatrix } from './model-math.mjs';
import { mul } from './vendor/gltf-math.mjs';
const options={clip:7,bone:2,frame:1,target:[0,35,0],pole:[-35,35,0]};
const clips=doc=>doc.sections.find(s=>s.type==='MDLA').anims;
const bones=doc=>doc.sections.find(s=>s.type==='MDLS').bones;
const change=fn=>{const doc=readMdlDoc(ikFixture());fn(doc,clips(doc)[0]);const skel=doc.sections.find(s=>s.type==='MDLS');if(skel.tail.length!==14+84*skel.bones.length)skel.tail=mdlsTail(skel.bones);return writeMdlDoc(doc);};
const pose=(bytes,bone,frame=1)=>Array.from(clips(readMdlDoc(bytes))[0].tracks[bone].data.slice(frame*9,frame*9+9));
function world(bytes,frame=1){const doc=readMdlDoc(bytes),animation=clips(doc)[0],out=[];for(const [i,b] of bones(doc).entries()){const local=restMatrix(Array.from(animation.tracks[i].data.slice(frame*9,frame*9+9)));out.push(b.parent<0?local:Float32Array.from(mul(out[b.parent],local)));}return out.map(m=>Array.from(m.slice(12,15)));}
const near=(a,b,tolerance=1e-4)=>a.forEach((v,i)=>assert(Math.abs(v-b[i])<tolerance,`${a} != ${b}`));
function bake(bytes=ikFixture(),extra={}){return bakeTwoBoneIk(bytes,{...options,start:1,end:1,...extra});}
function reject(extra,pattern=/target|pole|finite|Float32|reachable|root/i,bytes=ikFixture()){const before=bytes.slice();assert.throws(()=>bake(bytes,extra),pattern);assert.deepEqual(bytes,before);}

test('inspect identifies direct chain, native positions and visible default pole',()=>{const x=inspectIkChain(ikFixture(),options);assert.equal(x.root,0);assert.equal(x.middle,1);assert.equal(x.tip,2);assert.equal(x.fps,2);assert.equal(x.frameCount,2);assert.equal(x.mode,'mirror');assert.deepEqual(x.positions,[[-35,0,0],[0,0,0],[35,0,0]]);assert.equal(x.pole.length,3);assert(x.pole.every(Number.isFinite));});
test('independent right angle solution has exact native Float32 rotation deltas',()=>{const x=solveTwoBoneIk(ikFixture(),options),q=Math.fround(Math.PI/2);assert.deepEqual(x.poses,[{bone:0,delta:[0,0,0,0,0,q,1,1,1]},{bone:1,delta:[0,0,0,0,0,-q,1,1,1]}]);near(x.positions[1],[-35,35,0]);near(x.positions[2],options.target);assert(x.residual<1e-4);});
test('bake matches independently encoded whole MDL and never mutates source',()=>{const bytes=ikFixture(),before=bytes.slice(),expected=readMdlDoc(bytes);clips(expected)[0].tracks[0].data[14]=Math.PI/2;clips(expected)[0].tracks[1].data[14]=-Math.PI/2;const result=bake(bytes,{previewFrame:1});assert.deepEqual(result.bytes,writeMdlDoc(expected));assert.deepEqual(bytes,before);assert.deepEqual(result.preview,solveTwoBoneIk(bytes,options));});
test('opposite pole selects opposite elbow without changing target',()=>{const x=solveTwoBoneIk(ikFixture(),{...options,pole:[35,0,0]});near(x.positions[1],[0,0,0]);near(x.positions[2],options.target);});
test('actual 3D target and antiparallel segment alignment reach without stretching',()=>{for(const [target,pole] of [[[0,10,25],[-35,30,-10]],[[-70,35,0],[-35,35,0]],[[-105,0,0],[-35,35,0]]]){const x=solveTwoBoneIk(ikFixture(),{...options,target,pole});near(x.positions[2],target);assert(x.residual<7e-4);}});
test('rotated parents, positive uniform ancestors and nonuniform middle scales solve',()=>{const bytes=change((d,a)=>{bones(d).push({...structuredClone(bones(d)[2]),parent:2,name:'extra'});a.tracks.push(structuredClone(a.tracks[2]));for(let f=0;f<=2;f++){a.tracks[0].data.set([-35,10,5,.3,-.4,.8,2,2,2],f*9);a.tracks[2].data.set([35,0,0,.1,.2,.3,1,2,3],f*9);a.tracks[3].data.set([25,15,10,.2,-.1,.4,-2,3,4],f*9);}});const p=world(bytes),target=p[1].map((v,i)=>v+[45,40,15][i]),pole=p[1].map((v,i)=>v+[-20,50,25][i]);const x=solveTwoBoneIk(bytes,{...options,bone:3,target,pole});near(x.positions[2],target,2e-3);});
test('bake inclusive ranges, terminal loop sample and unrelated metadata remain byte exact',()=>{for(const [start,end] of [[0,0],[1,1],[2,2],[0,2]]){const bytes=change((d,a)=>{a.mode='loop';a.unk1=91;clips(d).push({...structuredClone(a),id:19,name:'Other'});d.sections.push({type:'MDLE',version:'0002',b8:0,data:Uint8Array.from({length:192},(_,i)=>(i*17)%256),tail:new Uint8Array()});});const expected=readMdlDoc(bytes);for(let f=start;f<=end;f++){clips(expected)[0].tracks[0].data[f*9+5]=Math.PI/2;clips(expected)[0].tracks[1].data[f*9+5]=-Math.PI/2;}assert.deepEqual(bake(bytes,{start,end}).bytes,writeMdlDoc(expected));}});
test('nonzero-start animated range preview uses exact continuity-context encoded deltas',()=>{const bytes=change((d,a)=>{a.frameCount=5;for(const [i,t] of a.tracks.entries()){t.data=new Float32Array(54);for(let f=0;f<=5;f++)t.data.set([i===0?-35:35,0,0,0,i===0?Math.PI/2+(f-3)*.0001:0,i===0?3+(f-2)*.3:0,1,1,1],f*9);}});const settings={start:2,end:5,target:[0,10,20],pole:[-35,35,20]};for(let f=2;f<=5;f++){const result=bake(bytes,{...settings,previewFrame:f});for(const p of result.preview.poses){const original=pose(bytes,p.bone,f),saved=pose(result.bytes,p.bone,f);for(let c=0;c<9;c++)assert.equal(saved[c],Math.fround(c<6?original[c]+p.delta[c]:original[c]*p.delta[c]));}near(world(result.bytes,f)[2],settings.target);if(f===5)assert.notDeepEqual(result.preview.poses,solveTwoBoneIk(bytes,{...options,...settings,frame:f}).poses,'Range continuity must be retained, rather than reconstructing a standalone branch');}});
test('owned no-op preserves all original bytes including signed-zero local components',()=>{const bytes=change((d,a)=>{for(const t of a.tracks)t.data[10]=-0;});assert.deepEqual(bake(bytes,{target:[35,0,0],pole:[0,35,0],start:0,end:2}).bytes,bytes);});
test('translations scales bind matrices children other tracks and events are untouched',()=>{const bytes=change((d,a)=>{bones(d).push({...structuredClone(bones(d)[2]),name:'child',parent:2});a.tracks.push(structuredClone(a.tracks[2]));});const result=bake(bytes).bytes,source=readMdlDoc(bytes),edited=readMdlDoc(result);assert.deepEqual(bones(edited),bones(source));assert.deepEqual(clips(edited)[0].events,clips(source)[0].events);for(const b of [2,3])assert.deepEqual(clips(edited)[0].tracks[b],clips(source)[0].tracks[b]);for(const b of [0,1]){assert.deepEqual(pose(result,b).slice(0,3),pose(bytes,b).slice(0,3));assert.deepEqual(pose(result,b).slice(6),pose(bytes,b).slice(6));}});
test('invalid selectors, options and preview sample fail before mutation',()=>{for(const extra of [{clip:8},{clip:'7'},{clip:-1},{clip:2**32},{bone:1},{bone:9},{bone:1.2},{start:-1},{start:2,end:1},{end:3},{start:NaN},{previewFrame:0},{previewFrame:1.2}])reject(extra,/clip|bone|chain|frame|sample|range/i);for(const value of [undefined,null,[],7])assert.throws(()=>bakeTwoBoneIk(ikFixture(),value),/options|operation/i);});
test('finite Float32 target and pole boundary validation rejects malformed overflow underflow',()=>{for(const key of ['target','pole'])for(const value of [null,[],[1,2],[1,2,3,4],new Float32Array(3),[NaN,1,2],[Infinity,1,2],[1e40,1,2],[1e-50,1,2],['1',1,2]])reject({[key]:value});});
test('zero-length, coincident target, collinear pole and unreachable targets reject explicitly',()=>{reject({target:[-35,0,0]},/root|coincident/i);reject({pole:[0,35,0]},/pole|collinear/i);reject({target:[100,100,100]},/unreachable/i);for(const joint of [1,2])reject({},/length|degenerate/i,change((d,a)=>a.tracks[joint].data[9]=0));reject({target:[-34,0,0],pole:[-35,35,0]},/unreachable/i,change((d,a)=>a.tracks[2].data[9]=10));});
test('signed, zero, nonuniform root or ancestor scales reject explicitly',()=>{for(const scale of [[-1,1,1],[1,-1,-1],[0,1,1],[1,2,1]])reject({},/scale|singular|invert/i,change((d,a)=>a.tracks[0].data.set(scale,15)));for(const scale of [[1,-1,1],[-1,-1,-1]])reject({},/scale/i,change((d,a)=>a.tracks[1].data.set(scale,15)));});

test('unsupported source and Float32 hierarchy or skin overflow fail visibly without source mutation',()=>{
 reject({},/Unsupported/i,change(d=>d.trailing=Uint8Array.of(1)));
 reject({},/Unsupported/i,change((d,a)=>a.tracks[2].data=a.tracks[2].data.slice(0,9)));
 const bytes=change((d,a)=>{bones(d)[0].matrix=restMatrix([-35,0,0,0,0,0,1e-8,1e8,1]);for(let f=0;f<=2;f++)a.tracks[0].data.set([1e32,1e32,1e32],f*9+6);});
 reject({target:[0,3.5e33,0],pole:[-3.5e33,3.5e33,0]},/skin|overflow|Float32/i,bytes);
});
test('baked output owns bytes and does not track subsequent stale source mutations',()=>{const bytes=ikFixture(),result=bake(bytes),saved=result.bytes.slice();bytes.fill(0);assert.deepEqual(result.bytes,saved);});

test('native additive Float32 loss that misses the target fails the final endpoint residual gate',()=>{const bytes=change((d,a)=>a.tracks[0].data[14]=1e8);reject({},/native Float32 endpoint residual/i,bytes);});

test('bent modal defaults preserve exact source bytes and zero native preview deltas',()=>{
 const bytes=change((d,a)=>{for(let f=0;f<=2;f++){a.tracks[0].data.set([.13,.2,.3],f*9+3);a.tracks[1].data.set([.4,.5,.6],f*9+3);}});
 const info=inspectIkChain(bytes,options),settings={target:info.positions[2],pole:info.pole,previewFrame:1};
 const result=bake(bytes,settings);
 assert.deepEqual(result.bytes,bytes);
 assert.deepEqual(result.preview.poses,[{bone:0,delta:[0,0,0,0,0,0,1,1,1]},{bone:1,delta:[0,0,0,0,0,0,1,1,1]}]);
 assert.deepEqual(result.preview.positions,info.positions);assert.equal(result.preview.residual,0);
 for(const p of result.preview.poses){const original=pose(bytes,p.bone),saved=pose(result.bytes,p.bone);for(let c=0;c<9;c++)assert.equal(saved[c],Math.fround(c<6?original[c]+p.delta[c]:original[c]*p.delta[c]));}
 const changedPole=info.positions[0].map((v,i)=>2*v-info.pole[i]),changed=bake(bytes,{target:info.positions[2],pole:changedPole,previewFrame:1});
 assert.notDeepEqual(changed.bytes,bytes,'An explicit pole change must still change the elbow');
 near(changed.preview.positions[2],info.positions[2]);assert(lengthBetween(changed.preview.positions[1],info.positions[1])>1);
});
const lengthBetween=(a,b)=>Math.hypot(...a.map((v,i)=>v-b[i]));
test('inspection permits unsupported original scales while solving validates only requested samples',()=>{
 for(const scale of [[1,2,1],[-1,1,1]]){
  const bytes=change((d,a)=>a.tracks[0].data.set(scale,6));
  const info=inspectIkChain(bytes,{...options,frame:0});assert(info.positions.flat().every(Number.isFinite));assert(info.pole.every(Number.isFinite));
  near(bake(bytes,{previewFrame:1}).preview.positions[2],options.target);
  reject({start:0,end:0},/scale/i,bytes);
 }
});

test('later default geometry retains range continuity after an earlier sample changes',()=>{
 const bytes=change((d,a)=>{a.tracks[0].data[23]=4*Math.PI+Math.PI/2;a.tracks[1].data[23]=-Math.PI/2;});
 const info=inspectIkChain(bytes,{...options,frame:2}),result=bake(bytes,{start:1,end:2,target:info.positions[2],pole:info.pole,previewFrame:2});
 for(const bone of [0,1])for(let c=3;c<6;c++)assert(Math.abs(pose(result.bytes,bone,2)[c]-pose(result.bytes,bone,1)[c])<=Math.PI,'A prior changed sample must prevent a default-frame Euler branch jump');
 for(const p of result.preview.poses){const original=pose(bytes,p.bone,2),saved=pose(result.bytes,p.bone,2);for(let c=0;c<9;c++)assert.equal(saved[c],Math.fround(c<6?original[c]+p.delta[c]:original[c]*p.delta[c]));}
 near(result.preview.positions[2],info.positions[2]);
});
test('an entirely unchanged bent default range remains byte exact',()=>{
 const bytes=change((d,a)=>{for(let f=0;f<=2;f++){a.tracks[0].data.set([.13,.2,.3],f*9+3);a.tracks[1].data.set([.4,.5,.6],f*9+3);}}),info=inspectIkChain(bytes,options);
 const result=bake(bytes,{start:0,end:2,target:info.positions[2],pole:info.pole,previewFrame:2});
 assert.deepEqual(result.bytes,bytes);assert(result.preview.poses.every(p=>p.delta.slice(0,6).every(v=>v===0)));
});
