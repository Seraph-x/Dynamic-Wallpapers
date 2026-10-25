import test from 'node:test';
import assert from 'node:assert/strict';
import { parseGltfSource } from './gltf-source.mjs';
import { rigGltf,changeGltf } from './gltf-fixtures.mjs';
import { buildGltfModel } from './gltf-model.mjs';
const build=source=>buildGltfModel(parseGltfSource(source),{identifier:'curve',fps:2,mode:'single'});
function output(j,source,values,type){
 const data=Float32Array.from(values),bytes=new Uint8Array(data.buffer),buffer=j.buffers.length,view=j.bufferViews.length,index=j.accessors.length,size=type==='VEC4'?4:3;
 j.buffers.push({uri:'curve.bin',byteLength:bytes.length});j.bufferViews.push({buffer,byteLength:bytes.length});j.accessors.push({bufferView:view,componentType:5126,type,count:values.length/size});source.files.push({path:'curve.bin',bytes});j.animations[0].samplers[0].output=index;
}
test('STEP and CUBICSPLINE translation preserve the chosen absolute sample times',()=>{
 const step=changeGltf(rigGltf(),j=>j.animations[0].samplers[0].interpolation='STEP');assert.equal(build(step).spec.animations[0].tracks[2][10],0);
 const cubic=changeGltf(rigGltf(),(j,s)=>{j.animations[0].samplers[0].interpolation='CUBICSPLINE';output(j,s,[0,0,0,35,0,0,0,120,0,0,0,0,35,60,0,0,0,0],'VEC3');});assert.equal(build(cubic).spec.animations[0].tracks[2][10],45);
});
test('quaternion interpolation becomes a continuous native Euler rotation',()=>{
 const source=changeGltf(rigGltf(),(j,s)=>{j.animations[0].channels[0].target.path='rotation';output(j,s,[0,0,0,1,0,0,1,0],'VEC4');});const track=build(source).spec.animations[0].tracks[2];assert(Math.abs(track[14]-Math.PI/2)<1e-6);assert(Math.abs(track[23]-Math.PI)<1e-6);
});
test('animation inputs require exact finite min/max and matrix targets reject',()=>{
 for(const change of [j=>delete j.accessors[j.animations[0].samplers[0].input].min,j=>j.accessors[j.animations[0].samplers[0].input].max=[2],j=>{delete j.nodes[2].translation;j.nodes[2].matrix=[1,0,0,0,0,1,0,0,0,0,1,0,35,0,0,1];}])assert.throws(()=>build(changeGltf(rigGltf(),change)),/animation.*(bound|min|max|matrix)|matrix.*animation/i);
});
