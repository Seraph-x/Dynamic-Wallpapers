import test from 'node:test';
import assert from 'node:assert/strict';
import { startEditor } from './runtime.mjs';
function fixture(){
 const events=[];let time=0,release;const gate=new Promise(resolve=>release=resolve);
 const controls={get time(){return time;},setTimeScale(){},getModelInfo:id=>id===1?{mdlPath:'rig.mdl',animations:[{id:2}]}:null,async seek(value){events.push(['seek',value]);time=value;},async setAnimationLayers(id,layers){events.push(['clip',id,layers]);await gate;events.push(['clip-ready']);}};
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
