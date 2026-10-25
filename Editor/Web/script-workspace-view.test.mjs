import test from 'node:test';
import assert from 'node:assert/strict';
import { scriptTargets,scriptInputSource } from './script-workspace-view.mjs';
const source='export function update(value) { return value; }';
const scene={objects:[{id:1,text:'Hello',color:{value:'1 0 0',script:source,future:1},origin:{value:'0 0 0',animation:{}},effects:[{visible:{value:true,script:source}}],future:{script:'unknown source'}},{id:2,alpha:1}]};
test('source targets retain readable bound fields and metadata with explicit reasons',()=>{
 const before=structuredClone(scene),targets=scriptTargets(scene,1);
 assert.equal(targets.find(t=>t.key==='color').state.source,source);
 assert.equal(targets.find(t=>t.key==='origin').state.editable,false);
 assert.match(targets.find(t=>t.key==='origin').state.reason,/binding/);
 assert.equal(targets.find(t=>t.key==='effects[0].visible').state.source,source);
 assert.equal(targets.find(t=>t.key==='text').state.editable,true);
 const unknown=targets.find(t=>t.key.startsWith('metadata:'));
 assert.equal(unknown.state.editable,false);assert.equal(unknown.source,'unknown source');assert.match(unknown.state.reason,/unknown|Unregistered/);
 assert(!targets.some(t=>t.selection?.layerId===2));assert.deepEqual(scene,before);
});
test('no layer never invents an editable target and duplicate identity remains read-only',()=>{
 assert.deepEqual(scriptTargets(scene,undefined),[]);
 assert(scriptTargets({objects:[{id:1},{id:1}]},1).every(t=>!t.state.editable));
});
test('missing numeric bases stay read-only and absent script differs from empty source',()=>{
 const targets=scriptTargets({objects:[{id:1,alpha:{value:1,script:''}}]},1);
 assert.equal(targets.find(t=>t.key==='brightness').state.editable,false);
 assert.equal(targets.find(t=>t.key==='alpha').state.kind,'script');
 assert.equal(targets.find(t=>t.key==='visible').state.kind,'constant');
});
test('real textarea input retains consistent CRLF style and exposes mixed input policy',()=>{
 assert.equal(scriptInputSource('a\nb\n','a\r\nb\r\n'),'a\r\nb\r\n');
 assert.equal(scriptInputSource('a\nb\n','a\nb\n'),'a\nb\n');
 assert.equal(scriptInputSource('a\nb\n','a\r\nb\n'),'a\nb\n');
 assert.equal(scriptInputSource('雪\n',''), '雪\n');
});

test('unrecognized non-array effects stay preserved and do not prevent source inspection',()=>{
 for(const effects of [{future:{script:'opaque source'}},'future-format',42,null]){
  const input={objects:[{id:1,effects}]},before=structuredClone(input),targets=scriptTargets(input,1);
  assert(targets.some(t=>t.key==='alpha'));assert(!targets.some(t=>t.key.startsWith('effects[')));
  assert.deepEqual(input,before);
 }
});
