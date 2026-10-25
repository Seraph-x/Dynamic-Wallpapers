import test from 'node:test';
import assert from 'node:assert/strict';
import { parseGltfSource } from './gltf-source.mjs';
import { gltfSkeleton } from './gltf-skeleton.mjs';
import { gltfGeometry } from './gltf-geometry.mjs';
import { rigGltf,changeGltf,gltfSource } from './gltf-fixtures.mjs';
import { createMdlDoc,readMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';

const materialPaths=['materials/left.json','materials/right.json'];
materialPaths[-1]='materials/default.json';
function convert(bundle=rigGltf(),options={}) {
  const source=parseGltfSource(bundle),scale=options.scale??1,skeleton=gltfSkeleton(source,options.sceneIndex??0,scale);
  return {...gltfGeometry(source,skeleton,{scale,materialPaths,...options}),skeleton};
}
function meshFixture({attributes={},node={},primitives,skin,nodes=[]}={}) {
  const chunks=[],bufferViews=[],accessors=[];let length=0;
  function accessor(values,type,componentType=5126,normalized,byteStride) {
    const size={SCALAR:1,VEC2:2,VEC3:3,VEC4:4,MAT4:16}[type],count=values.length/size,packed=new Uint8Array(values.buffer,values.byteOffset,values.byteLength);
    const bytes=byteStride?new Uint8Array((count-1)*byteStride+size*values.BYTES_PER_ELEMENT):packed,byteOffset=Math.ceil(length/4)*4;
    if(byteStride)for(let i=0;i<count;i++)bytes.set(packed.subarray(i*size*values.BYTES_PER_ELEMENT,(i+1)*size*values.BYTES_PER_ELEMENT),i*byteStride);
    chunks.push({byteOffset,bytes});length=byteOffset+bytes.length;
    bufferViews.push({buffer:0,byteOffset,byteLength:bytes.length,...(byteStride===undefined?{}:{byteStride})});
    const min=Array(size).fill(Infinity),max=Array(size).fill(-Infinity);
    for(let i=0;i<values.length;i++){min[i%size]=Math.min(min[i%size],values[i]);max[i%size]=Math.max(max[i%size],values[i]);}
    accessors.push({bufferView:bufferViews.length-1,componentType,type,count,min,max,...(normalized===undefined?{}:{normalized})});
    return accessors.length-1;
  }
  const attrs={POSITION:accessor(Float32Array.of(0,0,0,1,0,0,0,1,0),'VEC3')};
  for(const [key,value] of Object.entries(attributes))attrs[key]=accessor(...value);
  const selected=primitives?primitives(accessor,attrs):[{attributes:attrs}];
  const json={asset:{version:'2.0'},scene:0,scenes:[{nodes:Array.from({length:nodes.length+1},(_,i)=>i)}],
    nodes:[{name:'Mesh',mesh:0,...node},...nodes],meshes:[{primitives:selected}],bufferViews,accessors,buffers:[]};
  if(skin){json.nodes[0].skin=0;json.skins=[skin(accessor)];}
  const bytes=new Uint8Array(length);for(const chunk of chunks)bytes.set(chunk.bytes,chunk.byteOffset);
  json.buffers=[{uri:'geometry.bin',byteLength:length}];
  return gltfSource(json,[{path:'geometry.bin',bytes}]);
}
const joints=(...values)=>[Uint8Array.from(Array.from({length:3},()=>values).flat()),'VEC4',5121];
const weights=(...values)=>[Float32Array.from(Array.from({length:3},()=>values).flat()),'VEC4'];
const near=(actual,expected)=>actual.forEach((value,i)=>assert(Math.abs(value-expected[i])<1e-5,`${value} != ${expected[i]}`));

test('geometry keeps primitive separation, UVs and mapped skin and encodes real MDL',()=>{
  const bundle=rigGltf(),before=structuredClone(bundle),result=convert(bundle),[left,right]=result.meshes;
  assert.deepEqual(bundle,before);assert.equal(result.meshes.length,2);assert.equal(left.material,materialPaths[0]);assert.equal(right.material,materialPaths[1]);
  assert.deepEqual([...left.positions],[-50,-15,0,-20,-15,0,-20,15,0,-50,15,0]);
  assert.deepEqual([...left.uvs],[0,1,1,1,1,0,0,0]);assert.deepEqual([...left.indices],[0,1,2,0,2,3]);
  assert.equal(left.boneIdx[0],1);assert.equal(right.boneIdx[0],2);assert.equal(left.weights[0],1);
  assert.deepEqual(result.bounds,[-50,-15,0,50,15,0]);
  const bytes=writeMdlDoc(createMdlDoc({meshes:result.meshes,bones:result.skeleton.bones}));
  assert.equal(readMdlDoc(bytes).meshes.length,2);
});
test('rigid meshes bake world transforms, inverse-transpose normals and scaled bounds',()=>{
  const bundle=meshFixture({node:{translation:[10,5,0],scale:[2,1,1]},attributes:{
    NORMAL:[Float32Array.from({length:9},(_,i)=>i%3<2?Math.SQRT1_2:0),'VEC3'],
    TANGENT:[Float32Array.of(1,0,0,1,1,0,0,1,1,0,0,1),'VEC4']}});
  const {meshes,bounds,skeleton}=convert(bundle,{scale:2}),mesh=meshes[0];
  assert.deepEqual([...mesh.positions],[20,10,0,24,10,0,20,12,0]);
  near([...mesh.normals.slice(0,3)],[1/Math.sqrt(5),2/Math.sqrt(5),0]);assert.deepEqual([...mesh.tangents.slice(0,4)],[1,0,0,1]);
  assert.deepEqual([...mesh.boneIdx],[0,0,0,0,0,0,0,0,0,0,0,0]);assert.equal(skeleton.bones[0].matrix[12],20);
  assert.deepEqual(bounds,[20,10,0,24,12,0]);assert.equal(mesh.material,materialPaths[-1]);
});
test('a rigid reflection reverses triangle winding and tangent handedness',()=>{
  const result=convert(meshFixture({node:{scale:[-1,1,1]},attributes:{TANGENT:[Float32Array.of(1,0,0,1,1,0,0,1,1,0,0,1),'VEC4']}}));
  assert.deepEqual([...result.meshes[0].indices],[0,2,1]);assert.deepEqual([...result.meshes[0].tangents.slice(0,4)],[-1,0,0,-1]);
});
test('skinned data stays in source bind space, with nonidentity inverse binds used for bounds',()=>{
  const bundle=meshFixture({node:{translation:[100,0,0]},nodes:[{translation:[10,0,0]}],attributes:{JOINTS_0:joints(0,0,0,0),WEIGHTS_0:weights(1,0,0,0)},
    skin:a=>({joints:[1],inverseBindMatrices:a(Float32Array.of(1,0,0,0,0,1,0,0,0,0,1,0,-3,0,0,1),'MAT4')})});
  const {meshes,bounds}=convert(bundle,{scale:2});assert.deepEqual([...meshes[0].positions],[0,0,0,2,0,0,0,2,0]);
  assert.deepEqual(bounds,[14,0,0,16,2,0]);assert.equal(meshes[0].boneIdx[0],1);
});
test('multiple influence sets merge duplicate joints and preserve positive weight ratios',()=>{
  const bundle=meshFixture({nodes:[{},{}],attributes:{JOINTS_0:joints(0,1,0,0),WEIGHTS_0:weights(1,2,0,0),JOINTS_1:joints(0,1,0,0),WEIGHTS_1:weights(2,1,0,0)},skin:()=>({joints:[1,2]})});
  const {meshes}=convert(bundle);assert.deepEqual([...meshes[0].boneIdx.slice(0,4)],[1,2,0,0]);assert.deepEqual([...meshes[0].weights.slice(0,4)],[.5,.5,0,0]);
});
test('fifth positive influence, zero/negative weights, bad joints and incomplete sets reject',()=>{
  const fixture=()=>meshFixture({nodes:[{},{},{},{},{}],attributes:{JOINTS_0:joints(0,1,2,3),WEIGHTS_0:weights(1,1,1,1),JOINTS_1:joints(4,0,0,0),WEIGHTS_1:weights(1,0,0,0)},skin:()=>({joints:[1,2,3,4,5]})});
  assert.throws(()=>convert(fixture()),/four|4|influence/i);
  const valid=()=>meshFixture({nodes:[{}],attributes:{JOINTS_0:joints(0,0,0,0),WEIGHTS_0:weights(1,0,0,0)},skin:()=>({joints:[1]})});
  const mutate=(bundle,key,values)=>changeGltf(bundle,(j,s)=>{const a=j.accessors[j.meshes[0].primitives[0].attributes[key]],view=j.bufferViews[a.bufferView];s.files[1].bytes.set(new Uint8Array(values.buffer),view.byteOffset);});
  assert.throws(()=>convert(mutate(valid(),'WEIGHTS_0',Float32Array.of(0,0,0,0))),/zero|positive|weight/i);
  assert.throws(()=>convert(mutate(valid(),'WEIGHTS_0',Float32Array.of(-1,2,0,0))),/negative|weight/i);
  assert.throws(()=>convert(mutate(valid(),'JOINTS_0',Uint8Array.of(1,0,0,0))),/joint/i);
  assert.throws(()=>convert(changeGltf(valid(),j=>delete j.meshes[0].primitives[0].attributes.WEIGHTS_0)),/paired|weight|skin/i);
});
test('textured UV transform selects the required coordinates and preserves image orientation',()=>{
  const bundle=meshFixture({attributes:{TEXCOORD_0:[Float32Array.of(0,1,1,1,0,0),'VEC2']}});
  const result=convert(bundle,{materialUVs:{[-1]:{texCoord:0,offset:[2,3],scale:[2,1],rotation:Math.PI/2}}});
  near([...result.meshes[0].uvs],[1,3,1,5,2,3]);
  assert.throws(()=>convert(meshFixture(),{materialUVs:{[-1]:{texCoord:0}}}),/TEXCOORD_0|texture coordinate/i);
});
test('attribute types and counts, triangle indices and every unsupported primitive reject',()=>{
  const changes=[
    [j=>j.meshes[0].primitives[0].mode=1,/mode|triangle/i],
    [j=>j.meshes[0].primitives.push({attributes:{POSITION:0},mode:0}),/mode|triangle/i],
    [j=>j.meshes[0].primitives[0].targets=[{POSITION:0}],/morph/i],
    [j=>j.meshes[0].weights=[1],/morph/i],
    [j=>j.nodes[0].weights=[1],/morph/i],
    [j=>j.meshes[0].primitives[0].attributes.COLOR_0=0,/attribute/i],
    [j=>j.meshes[0].primitives[0].attributes.TEXCOORD_1=0,/attribute|coordinate/i],
    [j=>j.accessors[0].type='VEC2',/POSITION/i],
    [j=>j.meshes[0].primitives[0].attributes.NORMAL=0,/normal/i],
    [j=>j.meshes[0].primitives=[],/primitive|mesh/i],
  ];
  for(const [change,error] of changes)assert.throws(()=>convert(changeGltf(meshFixture(),change)),error);
  const indexed=indices=>meshFixture({primitives:(a,attrs)=>[{attributes:attrs,indices:a(Uint16Array.from(indices),'SCALAR',5123)}]});
  assert.throws(()=>convert(indexed([0,1,3])),/index|indice/i);assert.throws(()=>convert(indexed([0,1])),/triangle/i);
  const wrongCount=meshFixture({attributes:{TEXCOORD_0:[Float32Array.of(0,0),'VEC2']}});assert.throws(()=>convert(wrongCount),/count/i);
});
test('quantized attributes require declared extension and normalized integer weights are accepted',()=>{
  const bundle=meshFixture({nodes:[{}],attributes:{JOINTS_0:joints(0,0,0,0),WEIGHTS_0:[Uint8Array.of(255,0,0,0,255,0,0,0,255,0,0,0),'VEC4',5121,true]},skin:()=>({joints:[1]})});
  assert.equal(convert(bundle).meshes[0].weights[0],1);
  const quantized=meshFixture({primitives:(a,attrs)=>[{attributes:{...attrs,POSITION:a(Int16Array.of(0,0,0,2,0,0,0,2,0),'VEC3',5122,false,8)}}]});
  assert.throws(()=>convert(quantized),/quantization|POSITION/i);
  const result=convert(changeGltf(quantized,j=>j.extensionsUsed=['KHR_mesh_quantization']));assert.deepEqual(result.bounds,[0,0,0,2,2,0]);
});
test('selected scene geometry excludes other scene meshes and validates material/Float32 output',()=>{
  const bundle=changeGltf(meshFixture(),j=>{j.nodes.push({mesh:0,translation:[100,0,0]});j.scenes.push({nodes:[1]});});
  assert.equal(convert(bundle).meshes.length,1);assert.deepEqual(convert(bundle,{sceneIndex:1}).bounds,[100,0,0,101,1,0]);
  assert.throws(()=>convert(meshFixture(),{materialPaths:[]}),/material/i);
  assert.throws(()=>convert(meshFixture(),{scale:1e40}),/Float32|scale|overflow/i);
});
test('primitive restart indices reject even when within the vertex array',()=>{
  const restart=meshFixture({primitives:a=>[{attributes:{POSITION:a(new Float32Array(256*3),'VEC3')},indices:a(Uint8Array.of(0,1,255),'SCALAR',5121)}]});
  assert.throws(()=>convert(restart),/restart|index/i);
});
test('interleaved triangle index data rejects',()=>{
  const interleaved=meshFixture({primitives:(a,attrs)=>[{attributes:attrs,indices:a(Uint16Array.of(0,1,2),'SCALAR',5123,false,4)}]});
  assert.throws(()=>convert(interleaved),/index.*stride|stride.*index/i);
});
test('misaligned vertex elements reject',()=>{
  const unaligned=meshFixture({attributes:{TEXCOORD_0:[Uint8Array.of(0,0,255,0,0,255),'VEC2',5121,true]}});
  assert.throws(()=>convert(unaligned),/alignment|align|stride/i);
});
test('POSITION bounds are mandatory, finite and match actual decoded component extrema',()=>{
  for(const change of [j=>delete j.accessors[0].min,j=>delete j.accessors[0].max,j=>j.accessors[0].min=[-1,0,0],j=>j.accessors[0].max=[1,1],j=>j.accessors[0].max=[1e40,1,0]])assert.throws(()=>convert(changeGltf(meshFixture(),change)),/POSITION.*(min|max|bound)/i);
});
test('rigid mesh on a joint with a different inverse bind does not apply its node transform twice',()=>{
  const bundle=meshFixture({node:{translation:[-35,0,0],scale:[2,1,1]},nodes:[{mesh:0}],
    attributes:{JOINTS_0:joints(0,0,0,0),WEIGHTS_0:weights(1,0,0,0),NORMAL:[Float32Array.of(Math.SQRT1_2,Math.SQRT1_2,0,Math.SQRT1_2,Math.SQRT1_2,0,Math.SQRT1_2,Math.SQRT1_2,0),'VEC3']},
    skin:a=>({joints:[0],inverseBindMatrices:a(Float32Array.of(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1),'MAT4')})});
  const result=convert(changeGltf(bundle,j=>{delete j.nodes[0].skin;j.nodes[1].skin=0;j.meshes.push(structuredClone(j.meshes[0]));j.nodes[0].mesh=1;delete j.meshes[1].primitives[0].attributes.JOINTS_0;delete j.meshes[1].primitives[0].attributes.WEIGHTS_0;}));
  for(const mesh of result.meshes){assert.deepEqual([...mesh.positions],[0,0,0,1,0,0,0,1,0]);near([...mesh.normals.slice(0,3)],[Math.SQRT1_2,Math.SQRT1_2,0]);}
  assert.deepEqual(result.bounds,[-35,0,0,-33,1,0]);
});
test('scale is limited by the resulting MDL data rather than an arbitrary scalar cap',()=>{
  const bundle=meshFixture({primitives:a=>[{attributes:{POSITION:a(Float32Array.of(0,0,0,1e-10,0,0,0,1e-10,0),'VEC3')}}]});
  const {meshes}=convert(bundle,{scale:1e40});assert.equal(meshes[0].positions[3],Math.fround(Math.fround(1e-10)*1e40));
});
