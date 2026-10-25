import test from 'node:test';
import assert from 'node:assert/strict';
import { startEditor } from './runtime.mjs';
function fixture(){
 const events=[];let time=0,release;const gate=new Promise(resolve=>release=resolve);
 const controls={get time(){return time;},setTimeScale(){},getModelInfo:id=>id===1?{mdlPath:'rig.mdl',animations:[{id:2}],bones:[{},{}]}:null,async setBonePose(id,bone,pose){events.push(['pose',id,bone,pose]);},async seek(value){events.push(['seek',value]);time=value;},async setAnimationLayers(id,layers){events.push(['clip',id,layers]);await gate;events.push(['clip-ready']);}};
 const canvas=()=>({style:{},getContext:()=>null}),element={replaceChildren(){},append(){},ownerDocument:{createElement:canvas}};
 const editor=startEditor({version:1,session:'preview',generation:1,document:{title:'Test',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{objects:[]}}},{createScene:()=>({async load(){},setVolume(){},destroy(){}}),editorOf:()=>controls,element,report:async()=>{},onChange(){},onError(){},setEditingEnabled(){}});
 return {editor,events,release,async ready(){await editor.ready;await editor.command({type:'thaw',id:'thaw',session:'preview',generation:1});events.length=0;}};
}
test('model clip replacement and initial seek share one queue operation before a later Timeline seek',async()=>{
 const f=fixture();await f.ready();const preview=f.editor.previewModelClip(1,2);await Promise.resolve();const seek=f.editor.seek(.25);await Promise.resolve();assert.deepEqual(f.events,[['clip',1,[{animation:2,blend:1,rate:1,visible:true}]]]);f.release();await preview;await seek;assert.deepEqual(f.events.slice(1),[['clip-ready'],['seek',0],['seek',.25]]);assert.equal(f.editor.controls.time,.25);f.editor.destroy();
});
test('preview rejects a missing clip instead of changing playback',async()=>{
 const f=fixture();await f.ready();await assert.rejects(f.editor.previewModelClip(1,99),/clip/i);assert.deepEqual(f.events,[]);f.release();f.editor.destroy();
});
test('pose preview target seek remains atomic before later Timeline input',async()=>{
 const f=fixture();await f.ready();const preview=f.editor.previewModelClip(1,2,.5);await Promise.resolve();const seek=f.editor.seek(.75);f.release();await preview;await seek;
 assert.deepEqual(f.events.slice(1),[['clip-ready'],['seek',.5],['seek',.75]]);f.editor.destroy();
});
test('pose preview rejects invalid target time before changing native animation layers',async()=>{
 for(const time of [-1,NaN,Infinity,'1']){const f=fixture();await f.ready();try{const preview=f.editor.previewModelClip(1,2,time);f.release();await assert.rejects(preview,/time/i);assert.deepEqual(f.events,[]);}finally{f.release();f.editor.destroy();}}
});

const delta=[0,20,0,0,0,.25,1,1,1];
test('FK clip, seek and pose are atomic before a later Timeline seek',async()=>{
 const f=fixture();await f.ready();const preview=f.editor.previewModelBonePose(1,{animation:2,bone:0,time:.5,delta});await Promise.resolve();const seek=f.editor.seek(.75);f.release();await preview;await seek;
 assert.deepEqual(f.events.slice(1),[['clip-ready'],['seek',.5],['pose',1,0,{t:[0,20,0],r:[0,0,.25],s:[1,1,1]}],['seek',.75]]);f.editor.destroy();
});
test('FK restore reconstructs the authoritative scene and returns to original clock/play state',async()=>{
 const f=fixture();await f.ready();f.release();await f.editor.previewModelBonePose(1,{animation:2,bone:0,time:.5,delta});assert.equal(f.editor.playing,false);
 await f.editor.restoreModelPreview({time:.25,playing:true});assert.equal(f.editor.controls.time,.25);assert.equal(f.editor.playing,true);assert.deepEqual(f.events.slice(-2),[['seek',.5],['seek',.25]]);f.editor.destroy();
});
test('FK preview rejects invalid parameters before native calls and exposes closed/frozen errors',async()=>{
 for(const patch of [{bone:2},{bone:-1},{time:NaN},{time:-1},{delta:[]},{delta:[0,0,0,0,0,0,0,1,1]},{delta:[1e40,0,0,0,0,0,1,1,1]},{delta:[1e-50,0,0,0,0,0,1,1,1]}]){
  const f=fixture();await f.ready();f.release();await assert.rejects(f.editor.previewModelBonePose(1,{animation:2,bone:0,time:0,delta,...patch}));assert.deepEqual(f.events,[]);f.editor.destroy();
 }
 const f=fixture();await f.ready();f.release();await f.editor.command({type:'freeze',id:'f',session:'preview',generation:1});await assert.rejects(f.editor.previewModelBonePose(1,{animation:2,bone:0,time:0,delta}),/frozen/);await assert.rejects(f.editor.restoreModelPreview({time:0,playing:true}),/frozen/);f.editor.destroy();await assert.rejects(f.editor.restoreModelPreview({time:0,playing:true}),/closed/);
});

test('IK batch poses stay atomic before a later Timeline seek',async()=>{
 const f=fixture();await f.ready();const poses=[{bone:0,delta},{bone:1,delta:[0,0,0,0,0,-.25,1,1,1]}];const preview=f.editor.previewModelBonePoses(1,{animation:2,time:.5,poses});await Promise.resolve();const seek=f.editor.seek(.75);f.release();await preview;await seek;
 assert.deepEqual(f.events.slice(1),[['clip-ready'],['seek',.5],['pose',1,0,{t:[0,20,0],r:[0,0,.25],s:[1,1,1]}],['pose',1,1,{t:[0,0,0],r:[0,0,-.25],s:[1,1,1]}],['seek',.75]]);f.editor.destroy();
});
test('IK validates every pose selector before changing native layers',async()=>{
 for(const poses of [[],[{bone:0,delta},{bone:0,delta}],[{bone:0,delta},{bone:2,delta}],[{bone:0,delta},{bone:1,delta:[]}],[{bone:0,delta},{bone:-1,delta}]]){
  const f=fixture();await f.ready();f.release();await assert.rejects(f.editor.previewModelBonePoses(1,{animation:2,time:.5,poses}));assert.deepEqual(f.events,[]);f.editor.destroy();
 }
});
