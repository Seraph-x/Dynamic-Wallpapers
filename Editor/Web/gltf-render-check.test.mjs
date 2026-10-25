import test from 'node:test';
import assert from 'node:assert/strict';
import { validateGltfRender } from './gltf-render-check.mjs';
test('actual preview metadata must retain every bone, mesh and clip instead of accepting a partial parse',()=>{
 const candidate={spec:{bones:[{name:'Full bone name',parent:-1}],meshes:[{positions:new Float32Array(9),material:'a.json'}],animations:[{id:1,name:'Move',mode:'single',fps:29.97,frameCount:30}]}};
 const info={bones:[{name:'Full bone name',parent:-1}],meshes:[{vertexCount:3,materialPath:'a.json'}],animations:[{id:1,name:'Move',mode:'single',fps:Math.fround(29.97),frameCount:30}]};assert.doesNotThrow(()=>validateGltfRender(candidate,info));
 for(const change of [v=>v.bones=[],v=>v.bones[0].name='Full',v=>v.bones[0].parent=0,v=>v.meshes[0].vertexCount=1,v=>v.meshes[0].materialPath='b.json',v=>v.animations[0].frameCount=29]){const value=structuredClone(info);change(value);assert.throws(()=>validateGltfRender(candidate,value),/renderer/);}
});
