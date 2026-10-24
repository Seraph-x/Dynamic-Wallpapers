import test from 'node:test';
import assert from 'node:assert/strict';
import { SceneDocument } from './document.mjs';
import { animationState } from './animation.mjs';
const initial=()=>({title:'Timeline',entry:'scene.json',project:{type:'scene',future:true},scene:{objects:[{id:1,name:'Square',origin:'10 20 0',alpha:1,future:{kept:true}}]}});
test('property channels are native animations and each edit is exactly undoable',()=>{
  const input=initial(),doc=new SceneDocument(input);
  doc.animate(1,'origin',{type:'create',fps:30,length:150,mode:'loop'});
  let state=animationState(doc.snapshot().scene.objects[0],'origin');
  assert.equal(state.kind,'animation');assert.deepEqual(state.channels.map(c=>c[0].value),[10,20,0]);
  doc.animate(1,'origin',{type:'set-key',channel:0,frame:30,value:110});
  assert.deepEqual(doc.snapshot().scene.objects[0].origin.animation.c0.map(k=>[k.frame,k.value]),[[0,10],[30,110]]);
  doc.undo();assert.equal(animationState(doc.snapshot().scene.objects[0],'origin').channels[0].length,1);
  doc.redo();doc.markSaved();assert.equal(doc.dirty,false);
  doc.animate(1,'origin',{type:'move-key',channel:0,from:30,frame:60});
  assert.equal(animationState(doc.snapshot().scene.objects[0],'origin').channels[0][1].frame,60);
  doc.animate(1,'origin',{type:'delete-key',channel:0,frame:60});
  for(let i=0;i<4;i++)doc.undo();assert.deepEqual(doc.snapshot(),input);assert.equal(doc.canUndo,false);
  assert.deepEqual(input,initial());
});
test('invalid edits and occupied frames cannot change data or history',()=>{
  const doc=new SceneDocument(initial());doc.animate(1,'alpha',{type:'create',fps:30,length:60,mode:'single'});
  doc.animate(1,'alpha',{type:'set-key',channel:0,frame:30,value:0});
  const before=doc.snapshot();
  for(const edit of [{type:'set-key',channel:1,frame:10,value:1},{type:'set-key',channel:0,frame:-1,value:1},
    {type:'set-key',channel:0,frame:10,value:2},{type:'set-key',channel:0,frame:10,value:NaN},
    {type:'move-key',channel:0,from:30,frame:0},{type:'settings',fps:0,length:60,mode:'single'},
    {type:'settings',fps:30,length:10,mode:'single'}]){
    assert.throws(()=>doc.animate(1,'alpha',edit));assert.deepEqual(doc.snapshot(),before);
  }
  doc.undo();assert.equal(animationState(doc.snapshot().scene.objects[0],'alpha').channels[0].length,1);
  assert.throws(()=>doc.animate(1,'alpha',{type:'delete-key',channel:0,frame:0}));
});
test('unknown imported fields and custom handles survive key and settings edits',()=>{
  const source=initial();source.scene.objects[0].alpha={value:1,future:'wrapper',animation:{relative:true,future:'curve',c0:[{frame:0,value:0,custom:42,front:{enabled:true,x:.4,y:.2,future:'handle'},back:{enabled:true,x:1,y:0}},{frame:60,value:-.5}],options:{fps:30,length:60,mode:'mirror',future:'options'}}};
  const doc=new SceneDocument(source);
  doc.animate(1,'alpha',{type:'set-key',channel:0,frame:0,value:.8});
  let raw=doc.snapshot().scene.objects[0].alpha;
  assert(Math.abs(raw.animation.c0[0].value+.2)<1e-12);assert.equal(raw.animation.c0[0].custom,42);
  assert.deepEqual(raw.animation.c0[0].front,source.scene.objects[0].alpha.animation.c0[0].front);
  doc.animate(1,'alpha',{type:'settings',fps:60,length:120,mode:'loop'});
  raw=doc.snapshot().scene.objects[0].alpha;
  assert.equal(raw.future,'wrapper');assert.equal(raw.animation.future,'curve');assert.equal(raw.animation.options.future,'options');
  doc.animate(1,'alpha',{type:'set-key',channel:0,frame:60,value:.5,interpolation:'smooth'});
  assert.deepEqual(doc.snapshot().scene.objects[0].alpha.animation.c0[1].front,{enabled:true,x:1,y:0});
});
test('bindings require explicit conversion, unsupported curves remain untouched',()=>{
  const source=initial();source.scene.objects[0].alpha={value:.5,script:'export function update(v){return v;}',scriptproperties:{x:1},future:true};
  const doc=new SceneDocument(source);
  assert.equal(animationState(source.scene.objects[0],'alpha').kind,'bound');
  assert.throws(()=>doc.animate(1,'alpha',{type:'create',fps:30,length:60,mode:'loop'}));
  doc.animate(1,'alpha',{type:'create',fps:30,length:60,mode:'loop',replace:true,value:.7});
  const raw=doc.snapshot().scene.objects[0].alpha;assert.equal(raw.script,undefined);assert.equal(raw.future,true);assert.equal(raw.value,.7);
  doc.undo();assert.deepEqual(doc.snapshot(),source);
  const unsupported=initial();unsupported.scene.objects[0].origin={value:'10 20 0',animation:{c0:[],future:9,options:{fps:30,length:60,startpaused:true}}};
  const preserved=new SceneDocument(unsupported);assert.equal(animationState(unsupported.scene.objects[0],'origin').kind,'unsupported');
  assert.throws(()=>preserved.animate(1,'origin',{type:'set-key',channel:0,frame:1,value:2}));assert.deepEqual(preserved.snapshot(),unsupported);
});
test('copy/paste retains key metadata and removing a track restores a real constant',()=>{
  const doc=new SceneDocument(initial());doc.animate(1,'alpha',{type:'create',fps:30,length:60,mode:'single'});
  doc.animate(1,'alpha',{type:'set-key',channel:0,frame:0,value:.5,interpolation:'smooth'});
  const key=animationState(doc.snapshot().scene.objects[0],'alpha').channels[0][0];
  doc.animate(1,'alpha',{type:'paste-key',channel:0,frame:30,key});
  assert.equal(animationState(doc.snapshot().scene.objects[0],'alpha').channels[0][1].front.enabled,true);
  doc.animate(1,'alpha',{type:'remove',value:.75});assert.equal(doc.snapshot().scene.objects[0].alpha,.75);
  doc.undo();assert.equal(animationState(doc.snapshot().scene.objects[0],'alpha').channels[0].length,2);
});
