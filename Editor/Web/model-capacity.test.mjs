import test from 'node:test';
import assert from 'node:assert/strict';
import { observeModelCapacity } from './model-capacity.mjs';

// Isolated API-observation tests; actual GPU capacity is asserted separately in
// the real browser/CEF harness. These records verify transparent forwarding.
function context(size=48) {
  const program={},calls=[];
  const gl={CURRENT_PROGRAM:1,ACTIVE_UNIFORMS:2,
    getParameter(key){assert.equal(key,1);return program;},
    getProgramParameter(value,key){assert.equal(value,program);assert.equal(key,2);return 2;},
    getActiveUniform(value,i){assert.equal(value,program);return i?{name:'u_skin[0]',size}:{name:'u_mvp',size:1};},
    drawElements(...args){calls.push([this,args]);return 99;},drawArrays(){throw new Error('Native draw error');}};
  return {gl,calls};
}
test('capacity observation forwards exact context options/draw arguments and restores descriptors',()=>{
  const {gl,calls}=context(),options={alpha:false,preserveDrawingBuffer:false},requests=[];
  const canvas=Object.create({getContext(...args){requests.push([this,args]);return gl;}});
  const observer=observeModelCapacity(canvas),elements=gl.drawElements,arrays=gl.drawArrays;
  assert.equal(observer.capacity,undefined);assert.equal(canvas.getContext('webgl2',options),gl);
  assert.deepEqual(requests,[[canvas,['webgl2',options]]]);assert.equal(observer.capacity,undefined);
  assert.equal(gl.drawElements(4,6,2,0),99);assert.deepEqual(calls,[[gl,[4,6,2,0]]]);assert.equal(observer.capacity,48);
  assert.throws(()=>gl.drawArrays(),/Native draw error/);
  observer.dispose();observer.dispose();assert.equal(gl.drawElements,elements);assert.equal(gl.drawArrays,arrays);
  assert.equal(Object.hasOwn(canvas,'getContext'),false);
});
test('missing palette remains unavailable and observation failures stay explicit',()=>{
  const {gl}=context();gl.getActiveUniform=()=>({name:'u_mvp',size:1});
  const canvas={getContext(){return gl;}},original=Object.getOwnPropertyDescriptor(canvas,'getContext');
  const observer=observeModelCapacity(canvas);canvas.getContext('webgl2');gl.drawElements();assert.equal(observer.capacity,undefined);
  observer.dispose();assert.deepEqual(Object.getOwnPropertyDescriptor(canvas,'getContext'),original);
  gl.getParameter=()=>{throw new Error('Context lost during inspection');};
  const failed=observeModelCapacity(canvas);canvas.getContext('webgl2');assert.equal(gl.drawElements(),99);
  assert.match(failed.error.message,/Context lost/);assert.equal(failed.capacity,undefined);failed.dispose();
});
