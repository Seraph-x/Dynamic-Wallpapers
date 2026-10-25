import test from 'node:test';
import assert from 'node:assert/strict';
import { parseGltfSource } from './gltf-source.mjs';
import { gltfSource,rigGltf,changeGltf } from './gltf-fixtures.mjs';
import { gltfMaterials,bakeGltfPixels } from './gltf-materials.mjs';
test('unlit materials keep separate solid colors and explicit PBR consent metadata',()=>{
 const result=gltfMaterials(parseGltfSource(rigGltf()),'test');
 assert.equal(result.requiresUnlitConsent,false);assert.notEqual(result.materialPaths[0],result.materialPaths[1]);
 assert.equal(result.files.filter(f=>f.path.endsWith('.png')).length,3);
 const pbr=gltfMaterials(parseGltfSource(changeGltf(rigGltf(),j=>delete j.materials[0].extensions)),'test');assert.equal(pbr.requiresUnlitConsent,true);assert(pbr.notes.some(n=>n.kind==='pbr'));
 const pass=JSON.parse(new TextDecoder().decode(result.files.find(f=>f.path===result.materialPaths[0]).data)).passes[0];assert.equal(pass.defaultlight,false);assert.equal(pass.cullmode,'nocull');assert.equal(pass.shader,'generic4');
});
test('texture references and transforms preserve exact source bytes and require selected UV',()=>{
 const bytes=Uint8Array.of(137,80,78,71,13,10,26,10,1);
 const source=gltfSource({asset:{version:'2.0'},images:[{uri:'a.png'}],textures:[{source:0}],materials:[{extensions:{KHR_materials_unlit:{}},pbrMetallicRoughness:{baseColorTexture:{index:0,extensions:{KHR_texture_transform:{texCoord:1,offset:[.2,.3],scale:[2,3],rotation:.5}}}}}]},[{path:'a.png',bytes}]);
 const result=gltfMaterials(parseGltfSource(source),'test');assert.deepEqual(result.images[0].bytes,bytes);assert.deepEqual(result.materialUVs[0],{texCoord:1,offset:[.2,.3],scale:[2,3],rotation:.5});assert(result.notes.some(n=>n.kind==='sampling'));
});
test('linear color factor, opaque alpha and mask are baked explicitly without changing source pixels',()=>{
 const input=Uint8Array.of(255,128,0,100),before=input.slice();
 assert.deepEqual([...bakeGltfPixels(input,{factor:[.5,1,1,.5],alphaMode:'BLEND',alphaCutoff:.5})],[188,128,0,50]);
 assert.equal(bakeGltfPixels(input,{factor:[1,1,1,.5],alphaMode:'OPAQUE',alphaCutoff:.5})[3],255);
 assert.equal(bakeGltfPixels(input,{factor:[1,1,1,1],alphaMode:'MASK',alphaCutoff:.5})[3],0);assert.deepEqual(input,before);
});
test('invalid material references, factors and unsupported image formats reject',()=>{
 for(const patch of [j=>j.materials[0].pbrMetallicRoughness.baseColorFactor=[2,1,1,1],j=>j.materials[0].alphaMode='unknown',j=>j.materials[0].pbrMetallicRoughness.baseColorTexture={index:4},j=>j.materials[0].doubleSided='yes'])assert.throws(()=>gltfMaterials(parseGltfSource(changeGltf(rigGltf(),patch)),'test'));
 const source=gltfSource({asset:{version:'2.0'},images:[{uri:'image.webp'}]},[{path:'image.webp',bytes:Uint8Array.of(1,2,3)}]);assert.throws(()=>gltfMaterials(parseGltfSource(source),'test'),/PNG|JPEG|image/);
});
test('the default glTF PBR material also requires conversion consent when used',()=>{
 const source=changeGltf(rigGltf(),j=>{delete j.materials;for(const primitive of j.meshes[0].primitives)delete primitive.material;});assert.equal(gltfMaterials(parseGltfSource(source),'test').requiresUnlitConsent,true);
});
test('single-sided source materials explicitly require consent to the renderer’s two-sided appearance',()=>{
 const result=gltfMaterials(parseGltfSource(changeGltf(rigGltf(),j=>j.materials[0].doubleSided=false)),'test');assert.equal(result.requiresTwoSidedConsent,true);assert(result.notes.some(n=>n.kind==='two-sided'&&n.material===0));
});
test('BLEND materials reject instead of pretending the renderer supports per-mesh transparent depth',()=>{
 assert.throws(()=>gltfMaterials(parseGltfSource(changeGltf(rigGltf(),j=>j.materials[1].alphaMode='BLEND')),'test'),/unsupported.*BLEND.*depth/i);
});
