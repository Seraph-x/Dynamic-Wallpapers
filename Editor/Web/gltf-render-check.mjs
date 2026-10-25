export function validateGltfRender(candidate,info){
 const spec=candidate.spec;
 if(!info||info.bones?.length!==spec.bones.length||info.meshes?.length!==spec.meshes.length||info.animations?.length!==spec.animations.length)throw new Error('Actual renderer did not preserve glTF model structure');
 for(const [i,bone] of spec.bones.entries())if(info.bones[i].name!==bone.name||info.bones[i].parent!==bone.parent)throw new Error('Actual renderer cannot preserve the imported bone names/hierarchy');
 for(const [i,mesh] of spec.meshes.entries())if(info.meshes[i].vertexCount!==mesh.positions.length/3||info.meshes[i].materialPath!==mesh.material)throw new Error('Actual renderer cannot preserve imported geometry/material separation');
 for(const [i,clip] of spec.animations.entries())for(const key of ['id','name','mode','frameCount','fps'])if(info.animations[i][key]!== (key==='fps'?Math.fround(clip[key]):clip[key]))throw new Error('Actual renderer cannot preserve the imported animation');
}
