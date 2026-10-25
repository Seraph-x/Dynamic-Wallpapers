import { gltfArray } from './gltf-source.mjs';
import { validateGltfExtensions,gltfName } from './gltf-validation.mjs';
import { gltfSkeleton } from './gltf-skeleton.mjs';
import { gltfAnimations } from './gltf-animation.mjs';
import { gltfMaterials,prepareGltfTextures } from './gltf-materials.mjs';
import { gltfGeometry } from './gltf-geometry.mjs';
import { createMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';
import { validateGltfPoses } from './gltf-pose-validation.mjs';
const encode=value=>new TextEncoder().encode(JSON.stringify(value,null,2));
export function buildGltfModel(source,{identifier,scale=1,fps=30,mode='loop',scene=source.json.scene??0}={}){
 if(typeof identifier!=='string'||!/^[A-Za-z0-9_-]+$/.test(identifier))throw new Error('Invalid glTF resource identifier');
 if(!Number.isFinite(scale)||scale<=0||!Number.isFinite(Math.fround(scale))||!Number.isFinite(fps)||fps<=0||fps>240||!['loop','single'].includes(mode))throw new Error('Invalid glTF scale/FPS/playback options');
 validateGltfExtensions(source.json);
 const skeleton=gltfSkeleton(source,scene,scale),materials=gltfMaterials(source,identifier),geometry=gltfGeometry(source,skeleton,{scale,materialPaths:materials.materialPaths,materialUVs:materials.materialUVs}),clips=gltfAnimations(source,skeleton,{fps,scale,mode});
 const spec={bones:skeleton.bones,meshes:geometry.meshes,animations:clips.animations},mdlPath=`models/editor/${identifier}.mdl`;
 validateGltfPoses(spec);
 const notes=[...materials.notes];if(clips.omitted)notes.push({kind:'other-scene-animation',channels:clips.omitted});if(source.unknownChunks.length)notes.push({kind:'archived-glb-chunks',chunks:source.unknownChunks});
 const sourceCopy={entry:source.entry,files:source.files.map(file=>({path:file.path,bytes:file.bytes.slice()}))};
 return {identifier,mdlPath,spec,bounds:geometry.bounds,boneCount:spec.bones.length,source:sourceCopy,materials,requiresUnlitConsent:materials.requiresUnlitConsent,requiresTwoSidedConsent:materials.requiresTwoSidedConsent,animationInfo:clips.info,notes,
  scenes:gltfArray(source.json,'scenes').map((value,i)=>gltfName(value.name,`Scene ${i+1}`)),options:{scene,scale,fps,mode}};
}
export async function prepareGltfCandidate(model){
 const archive=`imports/editor/${model.identifier}`,files=[{path:model.mdlPath,data:writeMdlDoc(createMdlDoc(model.spec))},...await prepareGltfTextures(model.materials),
  ...model.source.files.map(file=>({path:`${archive}/source/${file.path}`,data:file.bytes.slice()}))];
 files.push({path:`${archive}/conversion.json`,data:encode({schema:1,sourceEntry:model.source.entry,model:model.mdlPath,options:model.options,animationInfo:model.animationInfo,notes:model.notes})});
 return Object.freeze({...model,files:files.map(file=>Object.freeze(file))});
}
