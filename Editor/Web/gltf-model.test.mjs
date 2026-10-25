import test from 'node:test';
import assert from 'node:assert/strict';
import { parseGltfSource } from './gltf-source.mjs';
import { rigGltf,changeGltf,glbSource } from './gltf-fixtures.mjs';
import { buildGltfModel } from './gltf-model.mjs';
import { readMdlDoc,writeMdlDoc,createMdlDoc } from './vendor/mdl-codec.mjs';
const build=(source=rigGltf(),options={})=>buildGltfModel(parseGltfSource(source),{identifier:'gltf-test',scale:1,fps:2,mode:'single',...options});
const fixtureJson=source=>JSON.parse(new TextDecoder().decode(source.files[0].bytes));
test('glTF model preserves hierarchy, inverse binds, geometry, skin, materials and source archive',()=>{
  const source=rigGltf(),before=structuredClone(source),model=build(source),spec=model.spec;
  assert.deepEqual(source,before);assert.deepEqual(spec.bones.map(b=>b.name),['Root','Left','Right','Mesh']);assert.deepEqual(spec.bones.map(b=>b.parent),[-1,0,0,0]);
  assert.equal(spec.bones[1].matrix[12],-35);assert.equal(spec.bones[2].matrix[12],35);assert.equal(spec.meshes.length,2);
  assert.deepEqual([...spec.meshes[0].positions],[-50,-15,0,-20,-15,0,-20,15,0,-50,15,0]);assert.equal(spec.meshes[0].boneIdx[0],1);assert.equal(spec.meshes[1].boneIdx[0],2);
  assert.equal(spec.meshes[1].weights[0],1);assert.notEqual(spec.meshes[0].material,spec.meshes[1].material);assert.deepEqual(model.bounds,[-50,-15,0,50,15,0]);
  assert.deepEqual(model.source.files,before.files);assert.equal(model.requiresUnlitConsent,false);const bytes=writeMdlDoc(createMdlDoc(spec));assert.deepEqual(writeMdlDoc(readMdlDoc(bytes)),bytes);
});
test('selected-FPS baking samples absolute time and reports fractional/zero duration without stretching',()=>{
  const model=build(rigGltf({duration:.37}),{fps:30}),clip=model.spec.animations[0],info=model.animationInfo[0],duration=Math.fround(.37);
  assert.equal(clip.frameCount,12);assert.equal(clip.fps,30);assert.equal(info.sourceDuration,duration);assert.equal(info.encodedDuration,.4);assert.equal(clip.tracks[2][6*9+1],Math.fround(60*.2/duration));assert.equal(clip.tracks[2][12*9+1],60);
  const source=changeGltf(rigGltf(),(j,s)=>{const input=j.accessors[j.animations[0].samplers[0].input],view=j.bufferViews[input.bufferView];input.count=1;input.min=[0];input.max=[0];new DataView(s.files[1].bytes.buffer).setFloat32(view.byteOffset,0,true);j.accessors[j.animations[0].samplers[0].output].count=1;});
  const zero=build(source,{fps:30});assert.equal(zero.spec.animations[0].frameCount,1);assert.equal(zero.animationInfo[0].sourceDuration,0);assert.equal(zero.animationInfo[0].encodedDuration,1/30);
});
test('animated rigid mesh nodes and non-joint ancestors remain actual bone tracks',()=>{
  const rigid=changeGltf(rigGltf(),j=>{delete j.nodes[3].skin;j.nodes[3].translation=[10,5,0];for(const p of j.meshes[0].primitives){delete p.attributes.JOINTS_0;delete p.attributes.WEIGHTS_0;}j.animations[0].channels[0].target.node=3;});
  const model=build(rigid),meshBone=model.spec.bones.findIndex(b=>b.name==='Mesh');assert(meshBone>=0);assert.equal(model.spec.meshes[0].positions[0],-40);assert.equal(model.spec.meshes[0].positions[1],-10);assert.equal(model.spec.meshes[0].boneIdx[0],meshBone);assert.equal(model.spec.animations[0].tracks[meshBone][10],30);
  const ancestor=changeGltf(rigGltf(),j=>{j.nodes.push({name:'Carrier',translation:[0,0,0],children:[2]});j.nodes[0].children=[1,3,4];j.animations[0].channels[0].target.node=4;});
  const result=build(ancestor),carrier=result.spec.bones.findIndex(b=>b.name==='Carrier'),right=result.spec.bones.findIndex(b=>b.name==='Right');assert.equal(result.spec.bones[right].parent,carrier);assert.equal(result.spec.animations[0].tracks[carrier][10],30);
});
test('GLB model matches equivalent external-buffer source and keeps original container bytes',()=>{
  const source=rigGltf(),json=fixtureJson(source);delete json.buffers[0].uri;const glb=glbSource(json,source.files[1].bytes),model=build(glb);assert.deepEqual(model.spec,build(source).spec);assert.deepEqual(model.source.files,glb.files);
});
test('PBR conversion is reported explicitly and unsupported extensions/morph/attributes reject',()=>{
  const pbr=changeGltf(rigGltf(),j=>delete j.materials[0].extensions);assert.equal(build(pbr).requiresUnlitConsent,true);
  for(const change of [j=>j.extensionsRequired=['KHR_draco_mesh_compression'],j=>j.meshes[0].primitives[0].targets=[{POSITION:0}],j=>j.meshes[0].primitives[0].mode=1,j=>j.meshes[0].primitives[0].attributes.COLOR_0=0,j=>j.materials[0].extensions.KHR_materials_clearcoat={}])assert.throws(()=>build(changeGltf(rigGltf(),change)),/unsupported|represent|extension|morph|mode|attribute/i);
});
test('bad hierarchy, binds, references, samples and options never produce a guessed model',()=>{
  for(const change of [j=>j.nodes[2].children=[0],j=>j.nodes[1].children=[2],j=>j.skins[0].joints=[1,99],j=>j.meshes[0].primitives[0].attributes.WEIGHTS_0=undefined,j=>j.nodes[2].scale=[0,1,1],j=>j.animations[0].samplers[0].interpolation='UNKNOWN',j=>j.animations[0].channels.push(j.animations[0].channels[0])])assert.throws(()=>build(changeGltf(rigGltf(),change)));
  for(const options of [{scale:0},{scale:NaN},{fps:0},{fps:241},{mode:'invalid'},{identifier:'../bad'}])assert.throws(()=>build(rigGltf(),options));
});
test('sampled parent worlds and skin positions must remain finite in actual Float32 playback',()=>{
 const source=changeGltf(rigGltf(),(j,s)=>{j.animations[0].channels[0].target.path='scale';j.animations[0].channels.push({sampler:0,target:{node:0,path:'scale'}});const accessor=j.accessors[j.animations[0].samplers[0].output],view=j.bufferViews[accessor.bufferView];for(let i=0;i<6;i++)new DataView(s.files[1].bytes.buffer).setFloat32(view.byteOffset+i*4,1e30,true);});
 assert.throws(()=>build(source),/Float32|overflow|finite/i);
});
