import { restMatrix,validateBindHierarchy } from './model-math.mjs';
import { mul,invert } from './vendor/gltf-math.mjs';
import { float32 } from './gltf-validation.mjs';
function hierarchy(bones,locals){const world=[];for(const [i,bone] of bones.entries())world.push(float32(bone.parent<0?locals[i]:mul(world[bone.parent],locals[i]),'sampled world matrix'));return world;}
export function validateGltfPoses(spec){
 const bind=hierarchy(spec.bones,spec.bones.map(b=>b.matrix)),inverse=bind.map(matrix=>{const value=invert(matrix);if(!value)throw new Error('Singular glTF bind matrix');return float32(value,'world bind inverse');});
 for(const clip of spec.animations)for(let frame=0;frame<=clip.frameCount;frame++){
  const locals=clip.tracks.map(track=>restMatrix(Array.from(track.subarray(frame*9,frame*9+9))));
  validateBindHierarchy(spec.bones.map((bone,i)=>({...bone,matrix:locals[i]})));
  const world=hierarchy(spec.bones,locals),skin=world.map((matrix,i)=>float32(mul(matrix,inverse[i]),'sampled skin matrix'));
  for(const mesh of spec.meshes)for(let vertex=0;vertex<mesh.positions.length/3;vertex++){
   const [x,y,z]=mesh.positions.subarray(vertex*3,vertex*3+3),position=[0,0,0];
   for(let k=0;k<4;k++){const weight=mesh.weights[vertex*4+k];if(!weight)continue;const m=skin[mesh.boneIdx[vertex*4+k]];for(let axis=0;axis<3;axis++)position[axis]+=(m[axis]*x+m[4+axis]*y+m[8+axis]*z+m[12+axis])*weight;}
   float32(position,'animated vertex position');
  }
 }
}
