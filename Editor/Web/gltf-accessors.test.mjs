import test from 'node:test';
import assert from 'node:assert/strict';
import { parseGltfSource } from './gltf-source.mjs';
import { readGltfAccessor } from './gltf-accessors.mjs';
import { accessorSource } from './gltf-fixtures.mjs';
const read=(input,index=0)=>readGltfAccessor(parseGltfSource(input),index);
test('accessors decode interleaved normalized values with actual subarray offsets',()=>{
  const data=new Uint8Array(20),view=new DataView(data.buffer);view.setUint16(4,65535,true);view.setUint16(6,32768,true);view.setUint16(12,0,true);view.setUint16(14,65535,true);
  const parsed=read(accessorSource(data,[{bufferView:0,byteOffset:4,componentType:5123,type:'VEC2',count:2,normalized:true}],[{buffer:0,byteLength:20,byteStride:8}]));assert.deepEqual([...parsed.data],[1,32768/65535,0,1]);assert.equal(parsed.size,2);
});
test('matrix byte/short accessors honor four-byte aligned columns',()=>{
  const data=Uint8Array.of(1,2,9,9,3,4,9,9,5,6,9,9,7,8,9,9);
  assert.deepEqual([...read(accessorSource(data,[{bufferView:0,componentType:5121,type:'MAT2',count:2}])).data],[1,2,3,4,5,6,7,8]);
});
test('matrix accessors allow omitted trailing alignment padding on the last element',()=>{
 const bytes=Uint8Array.of(1,2,3,99,4,5,6,99,7,8,9);assert.deepEqual([...read(accessorSource(bytes,[{bufferView:0,componentType:5121,type:'MAT3',count:1}])).data],[1,2,3,4,5,6,7,8,9]);
});
test('sparse accessors overwrite zero/base data using strictly ordered validated indices',()=>{
  const data=new Uint8Array(28);data.set([1,3],0);const v=new DataView(data.buffer);[10,20,30,40,50,60].forEach((x,k)=>v.setFloat32(4+k*4,x,true));
  const accessor={componentType:5126,type:'VEC3',count:4,sparse:{count:2,indices:{bufferView:0,componentType:5121},values:{bufferView:1}}};
  const views=[{buffer:0,byteOffset:0,byteLength:2},{buffer:0,byteOffset:4,byteLength:24}],input=accessorSource(data,[accessor],views);
  assert.deepEqual([...read(input).data],[0,0,0,10,20,30,0,0,0,40,50,60]);
  for(const indexes of [[1,1],[3,1],[1,4]]){const invalid=data.slice();invalid.set(indexes);assert.throws(()=>read(accessorSource(invalid,[accessor],views)),/sparse|index/i);}
});
test('accessors reject out-of-view reads, alignment, invalid strides and incompatible normalization',()=>{
  const bytes=new Uint8Array(32),base={bufferView:0,componentType:5126,type:'VEC3',count:2};
  for(const accessor of [{...base,count:3},{...base,byteOffset:2},{...base,count:0},{...base,count:1.5},{...base,normalized:true},{...base,componentType:999},{...base,type:'VEC5'}])assert.throws(()=>read(accessorSource(bytes,[accessor])));
  for(const byteStride of [1,6,8,256,-4])assert.throws(()=>read(accessorSource(bytes,[base],[{buffer:0,byteLength:32,byteStride}])));
  assert.throws(()=>read(accessorSource(bytes,[{componentType:5126,type:'VEC3',count:Number.MAX_SAFE_INTEGER}])));
});
test('accessors reject nonfinite values and malformed sparse metadata before publication',()=>{
  const data=new Uint8Array(16);new DataView(data.buffer).setFloat32(0,NaN,true);assert.throws(()=>read(accessorSource(data,[{bufferView:0,componentType:5126,type:'SCALAR',count:1}])),/finite/i);
  const base={componentType:5126,type:'VEC3',count:1};
  for(const sparse of [{count:2,indices:{bufferView:0,componentType:5121},values:{bufferView:0}},{count:1,indices:{bufferView:0,componentType:5126},values:{bufferView:0}},{count:1,indices:{bufferView:0,componentType:5121},values:{bufferView:8}}])assert.throws(()=>read(accessorSource(new Uint8Array(16),[{...base,sparse}])));
});
function rejectBeforeDenseAllocation(input,error) {
  const source=parseGltfSource(input),original=globalThis.Float64Array;let allocations=0;
  globalThis.Float64Array=new Proxy(original,{construct(){allocations++;throw new Error('Unexpected dense accessor allocation');}});
  try{assert.throws(()=>readGltfAccessor(source,0),error);assert.equal(allocations,0);}finally{globalThis.Float64Array=original;}
}
test('invalid large base accessors validate bounds and offsets before dense allocation',()=>{
  const base={componentType:5126,type:'SCALAR',count:100_000_000};
  rejectBeforeDenseAllocation(accessorSource(new Uint8Array(4),[{...base,bufferView:0}]),/bounds/i);
  rejectBeforeDenseAllocation(accessorSource(new Uint8Array(4),[{...base,bufferView:99}]),/bufferView/i);
  rejectBeforeDenseAllocation(accessorSource(new Uint8Array(4),[{...base,byteOffset:4}]),/without a view/i);
});
test('malformed sparse metadata and view bounds reject before dense allocation',()=>{
  const bytes=new Uint8Array(8),base={componentType:5126,type:'SCALAR',count:100_000_000};
  for(const sparse of [
    {count:100_000_001,indices:{bufferView:0,componentType:5121},values:{bufferView:0}},
    {count:1,indices:{bufferView:0,componentType:5126},values:{bufferView:0}},
    {count:1,indices:{bufferView:99,componentType:5121},values:{bufferView:0}},
    {count:1,indices:{bufferView:0,componentType:5121},values:{bufferView:0,byteOffset:8}},
  ])rejectBeforeDenseAllocation(accessorSource(bytes,[{...base,sparse}]),/sparse|bufferView|bounds/i);
});
test('sparse index ordering/range and all input float values reject before dense allocation',()=>{
  const bytes=new Uint8Array(12),values=new DataView(bytes.buffer),views=[{buffer:0,byteLength:2},{buffer:0,byteOffset:4,byteLength:8}];
  const accessor={componentType:5126,type:'SCALAR',count:100_000_000,sparse:{count:2,indices:{bufferView:0,componentType:5121},values:{bufferView:1}}};
  for(const indices of [[1,1],[2,1]]){const input=bytes.slice();input.set(indices);rejectBeforeDenseAllocation(accessorSource(input,[accessor],views),/ordered|unique/i);}
  const outOfRange={...accessor,count:2};bytes.set([0,2]);rejectBeforeDenseAllocation(accessorSource(bytes,[outOfRange],views),/range/i);
  bytes.set([0,1]);values.setFloat32(8,Infinity,true);rejectBeforeDenseAllocation(accessorSource(bytes,[accessor],views),/nonfinite/i);
  values.setFloat32(0,NaN,true);rejectBeforeDenseAllocation(accessorSource(bytes,[{bufferView:0,componentType:5126,type:'SCALAR',count:3}]),/nonfinite/i);
});
