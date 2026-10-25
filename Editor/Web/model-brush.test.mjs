import test from 'node:test';
import assert from 'node:assert/strict';
import { createWeightStroke } from './model-brush.mjs';
const mesh=(weights=[1,0,0,0],joints=[0,0,0,0])=>({vertexCount:3,positions:Float32Array.of(0,0,0,5,0,0,10,0,0),indices:Uint32Array.of(0,1,2),
  weights:Float32Array.from([...weights,...weights,...weights]),joints:Uint32Array.from([...joints,...joints,...joints])});
const options=()=>({mesh:mesh(),points:[[0,0],[5,0],[10,0]],bone:1,boneCount:5,radius:10,target:1,strength:.5});
const weight=(preview,vertex,joint)=>Array.from({length:4},(_,k)=>preview.joints[vertex*4+k]===joint?preview.weights[vertex*4+k]:0).reduce((a,b)=>a+b,0);
test('brush uses linear point falloff and selected-weight interpolation, without mutating source',()=>{
  const input=options(),before=structuredClone(input),stroke=createWeightStroke(input);stroke.move([0,0]);
  const preview=stroke.preview();assert.equal(weight(preview,0,1),.5);assert.equal(weight(preview,1,1),.25);assert.equal(weight(preview,2,1),0);
  assert.equal(weight(preview,0,0),.5);assert.deepEqual(input,before);assert.equal(stroke.edits().length,2);
  preview.weights.fill(9);assert.equal(weight(stroke.preview(),0,1),.5);
});
test('continuous segments close gaps and maximum coverage makes sample frequency/repeated samples irrelevant',()=>{
  const first=createWeightStroke(options()),split=createWeightStroke(options());first.move([-10,2]);first.move([20,2]);
  for(const point of [[-10,2],[0,2],[5,2],[5,2],[10,2],[20,2]])split.move(point);
  assert.deepEqual(first.edits(),split.edits());assert(first.edits().every(e=>Math.abs(e.influences.find(i=>i.joint===1).weight-.4)<1e-12));
});
test('brush normalizes duplicates and retains other influence ratios, omitting only exact zeros',()=>{
  const stroke=createWeightStroke({...options(),mesh:mesh([2,2,2,0],[0,0,2,0]),strength:1});stroke.move([0,0]);
  const preview=stroke.preview();assert.equal(weight(preview,0,1),1);assert.equal(weight(preview,0,0),0);
  assert(Math.abs(weight(preview,1,0)-1/3)<1e-7);assert(Math.abs(weight(preview,1,2)-1/6)<1e-7);assert.equal(weight(preview,1,1),.5);
});
test('unrepresentable fifth influence and sole-weight reduction reject the whole preview',()=>{
  for(const patch of [{mesh:mesh([1,1,1,1],[0,2,3,4])},{bone:0,target:0}]){
    const stroke=createWeightStroke({...options(),...patch});stroke.move([0,0]);assert.throws(()=>stroke.edits(),/four|surviving|influence/i);
  }
});
test('no coverage, zero strength and equal target produce no edits',()=>{
  for(const patch of [{strength:0},{bone:0,target:1}]){const stroke=createWeightStroke({...options(),...patch});stroke.move([0,0]);assert.deepEqual(stroke.edits(),[]);}
  const stroke=createWeightStroke(options());stroke.move([50,50]);assert.deepEqual(stroke.edits(),[]);
});
test('invalid brush/source inputs are rejected explicitly',()=>{
  for(const patch of [{radius:0},{radius:Infinity},{target:-1},{target:2},{strength:NaN},{bone:5},{boneCount:0},{points:[[0,0]]},{points:[[0,NaN],[1,0],[2,0]]},{mesh:mesh([-1,0,0,0])},{mesh:mesh([0,0,0,0])},{mesh:mesh([1,0,0,0],[8,0,0,0])}])assert.throws(()=>createWeightStroke({...options(),...patch}));
  const stroke=createWeightStroke(options());assert.throws(()=>stroke.move([Infinity,0]));
});
test('native Float32 underflow is explicit while tiny finite map radii remain valid',()=>{
  const tiny=createWeightStroke({...options(),radius:Number.MIN_VALUE,strength:1});tiny.move([0,0]);assert.equal(weight(tiny.preview(),0,1),1);
  const unrepresentable=createWeightStroke({...options(),target:Number.MIN_VALUE,strength:1});unrepresentable.move([0,0]);assert.throws(()=>unrepresentable.edits(),/Float32/);
  const overflow=createWeightStroke(options());overflow.move([1e308,0]);assert.throws(()=>overflow.move([-1e308,0]),/numeric|representation/);
});
