import test from 'node:test';
import assert from 'node:assert/strict';
import { readMdlDoc } from './vendor/mdl-codec.mjs';
import { inspectModel } from './model.mjs';
import { createImagePuppet,imagePuppetStats } from './image-puppet.mjs';

export const imageModel=()=>({width:80,height:40,material:'materials/picture.json',future:{retained:true}});
export const imageMaterial=()=>({future:'material',passes:[{shader:'genericimage2',textures:['picture'],blending:'translucent',defaultlight:true,future:'pass'}]});
export const creation=()=>({model:imageModel(),material:imageMaterial(),modelPath:'models/new.json',mdlPath:'models/new.mdl',materialPath:'materials/new.json',columns:3,rows:2,rootName:'Root'});
test('image mesh has correct centered vertices, top-left UVs, winding and root skin',()=>{
  const options=creation(),before=structuredClone(options),result=createImagePuppet(options),info=inspectModel(result.files[0].data);
  assert.deepEqual(options,before);assert.deepEqual(imagePuppetStats(options),{vertices:12,triangles:12,indexBytes:72,vertexBytes:960});
  assert.equal(info.bones.length,1);assert.equal(info.bones[0].name,'Root');assert.equal(info.bones[0].parent,-1);
  const mesh=info.meshes[0];assert.equal(mesh.vertexCount,12);assert.equal(mesh.indices.length,36);
  assert.deepEqual([...mesh.positions.slice(0,3)],[-40,20,0]);assert.deepEqual([...mesh.positions.slice(-3)],[40,-20,0]);
  for(let i=0;i<mesh.vertexCount;i++){assert.deepEqual([...mesh.joints.slice(i*4,i*4+4)],[0,0,0,0]);assert.deepEqual([...mesh.weights.slice(i*4,i*4+4)],[1,0,0,0]);}
  for(let i=0;i<mesh.indices.length;i+=3){const [a,b,c]=[...mesh.indices.slice(i,i+3)].map(v=>mesh.positions.slice(v*3,v*3+3));assert((b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])>0);}
  const raw=readMdlDoc(result.files[0].data).meshes[0].vertexData,view=new DataView(raw.buffer,raw.byteOffset,raw.byteLength);
  assert.equal(view.getFloat32(72,true),0);assert.equal(view.getFloat32(76,true),0);
  assert.equal(view.getFloat32(11*80+72,true),1);assert.equal(view.getFloat32(11*80+76,true),1);
  const clip=info.animations[0];assert.equal(clip.name,'Rest');assert.deepEqual([...clip.tracks[0].data],[0,0,0,0,0,0,1,1,1,0,0,0,0,0,0,1,1,1]);
});
test('new model/material resources retain metadata and texture references without lighting',()=>{
  const result=createImagePuppet(creation()),decode=file=>JSON.parse(new TextDecoder().decode(file.data));
  const material=decode(result.files[1]),model=decode(result.files[2]);
  assert.equal(model.material,'materials/new.json');assert.equal(model.puppet,'models/new.mdl');assert.equal(model.width,80);assert.equal(model.height,40);assert.equal(model.autosize,false);
  assert.deepEqual(model.future,{retained:true});assert.equal(material.future,'material');assert.equal(material.passes[0].future,'pass');
  assert.equal(material.passes[0].defaultlight,false);assert.deepEqual(material.passes[0].textures,['picture']);
});
test('invalid image sources and unrepresentable native dimensions/counts fail before publication',()=>{
  for(const patch of [{columns:0},{rows:1.5},{columns:NaN},{columns:2**31,rows:1},{rootName:'Bad\0root'},
    {rootName:''},{rootName:'\ud800'},{model:{...imageModel(),width:Infinity}},{model:{...imageModel(),height:1e-50}},
    {model:{...imageModel(),width:1e40}},{model:{...imageModel(),puppet:'old.mdl'}},{model:{...imageModel(),autosize:true}},
    {model:{material:'a.json'}},{mdlPath:'../outside'}, {material:{passes:[]}},
    {material:{passes:[{shader:'custom',textures:['picture']}]}},
    {material:{passes:[{shader:'genericimage2',textures:['picture','mask']}]}},
    {material:{passes:[{shader:'genericimage2',textures:['picture'],constantshadervalues:{alpha:.5}}]}}]){
    const input={...creation(),...patch},before=structuredClone(input);assert.throws(()=>createImagePuppet(input));assert.deepEqual(input,before);
  }
});
test('native 32-bit mesh indices work beyond 65535 vertices without coarsening',()=>{
  const result=createImagePuppet({...creation(),columns:256,rows:256}),mesh=inspectModel(result.files[0].data).meshes[0];
  assert.equal(mesh.vertexCount,66049);assert.equal(mesh.indices.length,256*256*6);assert.equal(mesh.indices[mesh.indices.length-1],66048);
});
test('declared dimensions and individual grid steps must survive Float32 encoding',()=>{
  for(const width of [3.5e38,1e-44])assert.throws(()=>createImagePuppet({...creation(),columns:32,model:{...imageModel(),width}}),/Float32|spacing/i);
});

test('render target texture names cannot be treated as image files',()=>{
  for(const texture of ['_rt_FullFrameBuffer','_rt_imageLayer']){
    const options=creation();options.material.passes[0].textures=[texture];
    assert.throws(()=>createImagePuppet(options),/render.target/i);
  }
});
test('explicit image layer sizes determine mesh geometry without baking layer scale',()=>{
  for(const layerSize of ['160 80',{value:'160 80',future:true}]){
    const input={...creation(),layerSize};const result=createImagePuppet(input),mesh=inspectModel(result.files[0].data).meshes[0];
    assert.deepEqual([...mesh.positions.slice(0,3)],[-80,40,0]);assert.deepEqual([...mesh.positions.slice(-3)],[80,-40,0]);
    assert.equal(JSON.parse(new TextDecoder().decode(result.files[2].data)).width,80);
  }
  assert.deepEqual([...inspectModel(createImagePuppet({...creation(),layerSize:'0 0'}).files[0].data).meshes[0].positions.slice(0,3)],[-40,20,0]);
  for(const layerSize of ['0 80','-80 40','bad 40',[],{value:'Infinity 40'}])assert.throws(()=>createImagePuppet({...creation(),layerSize}),/size|dimensions/i);
});
test('property-bound or scripted image sizes are explicit unsupported sources, never baked snapshots',()=>{
  for(const binding of [{user:'pictureSize'},{script:'scripts/size.js'},{animation:{options:{fps:30}}}]){
    assert.throws(()=>createImagePuppet({...creation(),layerSize:{value:'160 80',...binding}}),/bound|controlled|constant/i);
  }
});
