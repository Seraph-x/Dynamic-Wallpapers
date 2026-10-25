import test from 'node:test';
import assert from 'node:assert/strict';
import { WeightBrushController } from './model-brush-controller.mjs';
class Canvas extends EventTarget {
  captures=new Set();width=320;height=180;
  getBoundingClientRect(){return {left:0,top:0,width:320,height:180};}
  setPointerCapture(id){this.captures.add(id);}hasPointerCapture(id){return this.captures.has(id);}releasePointerCapture(id){this.captures.delete(id);}focus(){}
}
const emit=(target,type,patch={})=>{const e=new Event(type,{cancelable:true});Object.assign(e,{pointerId:1,isPrimary:true,button:0,clientX:0,clientY:0,...patch});target.dispatchEvent(e);};
async function fixture() {
  const canvas=new Canvas(),keys=new EventTarget(),seen=[],errors=[];let finish;
  const context={move:p=>seen.push(['move',p]),async commit(){seen.push(['commit']);},cancel(){seen.push(['cancel']);}};
  const controller=new WeightBrushController({canvas,keys,enabled:()=>true,prepare:()=>new Promise(r=>{finish=r;}),onState:()=>{},onError:e=>errors.push(e),onFinish:()=>{},onHover:()=>{}});
  return {canvas,keys,seen,errors,controller,resolve:()=>finish(context)};
}
test('release during asynchronous preparation commits the complete buffered path once',async()=>{
  const f=await fixture();emit(f.canvas,'pointerdown');emit(f.canvas,'pointermove',{clientX:10});emit(f.canvas,'pointerup',{clientX:20});f.resolve();await f.controller.settled();
  assert.deepEqual(f.seen,[['move',[0,0]],['move',[10,0]],['move',[20,0]],['commit']]);assert.equal(f.controller.busy,false);assert.deepEqual(f.errors,[]);
});
test('Escape/pointercancel/lost capture before preparation never publishes a late stroke',async()=>{
  for(const type of ['Escape','pointercancel','lostpointercapture']){
    const f=await fixture();emit(f.canvas,'pointerdown');
    if(type==='Escape')emit(f.keys,'keydown',{key:'Escape'});else emit(f.canvas,type);
    f.resolve();await f.controller.settled();assert.deepEqual(f.seen,[['cancel']]);assert.equal(f.controller.busy,false);
  }
});
test('pending and active strokes block barriers; cancellation error identity is stable',async()=>{
  const f=await fixture();emit(f.canvas,'pointerdown');let first;try{f.controller.assertIdle();}catch(e){first=e;}
  f.resolve();await f.controller.settled();assert.throws(()=>f.controller.assertIdle(),e=>e===first);
  emit(f.keys,'keydown',{key:'Escape'});assert.doesNotThrow(()=>f.controller.assertIdle());assert.deepEqual(f.seen,[['move',[0,0]],['cancel']]);
});
test('secondary pointers cannot replace or terminate the owning stroke',async()=>{
  const f=await fixture();emit(f.canvas,'pointerdown');emit(f.canvas,'pointerdown',{pointerId:2});f.resolve();await f.controller.settled();
  emit(f.canvas,'pointerup',{pointerId:2});assert.equal(f.controller.busy,true);emit(f.canvas,'pointerup');await f.controller.settled();assert.equal(f.seen.filter(v=>v[0]==='commit').length,1);
});
test('destroy cancels input and suppresses late preparation without hiding failures',async()=>{
  const f=await fixture();emit(f.canvas,'pointerdown');f.controller.destroy();f.resolve();await f.controller.settled();assert.deepEqual(f.seen,[['cancel']]);
});
test('implicit lost capture after an early pointerup preserves the buffered release',async()=>{
  const f=await fixture();emit(f.canvas,'pointerdown');emit(f.canvas,'pointerup');emit(f.canvas,'lostpointercapture');f.resolve();await f.controller.settled();assert.equal(f.seen.filter(v=>v[0]==='commit').length,1);
});
test('synchronous preparation failure releases ownership and reports the actual error',async()=>{
  const canvas=new Canvas(),errors=[],failure=new Error('Invalid pending draft');
  const controller=new WeightBrushController({canvas,keys:new EventTarget(),enabled:()=>true,prepare:()=>{throw failure;},onState:()=>{},onError:e=>errors.push(e),onFinish:()=>{},onHover:()=>{}});
  emit(canvas,'pointerdown');await controller.settled();assert.equal(controller.busy,false);assert.deepEqual(errors,[failure]);assert.equal(canvas.captures.size,0);
});

test('a released pending stroke permits a barrier to await completion rather than treating it as unfinished',async()=>{
  const f=await fixture();emit(f.canvas,'pointerdown');emit(f.canvas,'pointerup');assert.doesNotThrow(()=>f.controller.assertIdle());
  f.resolve();await f.controller.settled();assert.equal(f.controller.busy,false);assert.equal(f.seen.filter(v=>v[0]==='commit').length,1);
});
test('every successful stroke releases exactly its own barrier, even without an edit',async()=>{
  const canvas=new Canvas(),markers=[];
  const controller=new WeightBrushController({canvas,keys:new EventTarget(),enabled:()=>true,prepare:async()=>({move(){},async commit(){},cancel(){}}),onState:()=>{},onError:e=>{throw e;},onFinish:e=>markers.push(e),onHover:()=>{}});
  emit(canvas,'pointerdown');let marker;try{controller.assertIdle();}catch(e){marker=e;}
  emit(canvas,'pointerup');await controller.settled();assert.deepEqual(markers,[marker]);
});
test('failed completion releases its own barrier and reports the failure distinctly',async()=>{
  const canvas=new Canvas(),markers=[],errors=[],failure=new Error('Write failed');
  const controller=new WeightBrushController({canvas,keys:new EventTarget(),enabled:()=>true,prepare:async()=>({move(){},async commit(){throw failure;},cancel(){}}),onState:()=>{},onError:e=>errors.push(e),onFinish:e=>markers.push(e),onHover:()=>{}});
  emit(canvas,'pointerdown');let marker;try{controller.assertIdle();}catch(e){marker=e;}
  emit(canvas,'pointerup');await controller.settled();assert.deepEqual(markers,[marker]);assert.deepEqual(errors,[failure]);
});
