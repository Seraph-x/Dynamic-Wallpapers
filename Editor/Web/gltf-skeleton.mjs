import { gltfArray } from './gltf-source.mjs';
import { readGltfAccessor } from './gltf-accessors.mjs';
import { finiteVector,gltfRef,gltfName,quaternion,float32 } from './gltf-validation.mjs';
import { restPose,validateBindHierarchy } from './model-math.mjs';
import { ident,mul,invert,composeTRSQ,decompose } from './vendor/gltf-math.mjs';
function nodePose(node){
  if(!node||typeof node!=='object'||Array.isArray(node))throw new Error('Invalid glTF node');
  if(node.matrix!==undefined){
    if(['translation','rotation','scale'].some(key=>node[key]!==undefined))throw new Error('glTF node cannot combine matrix and TRS');
    const matrix=finiteVector(node.matrix,16,'node matrix');restPose(float32(matrix,'node matrix'));return {...decompose(matrix),matrix:Float64Array.from(matrix)};
  }
  const t=finiteVector(node.translation??[0,0,0],3,'translation'),r=quaternion(node.rotation??[0,0,0,1]),s=finiteVector(node.scale??[1,1,1],3,'scale'),matrix=composeTRSQ(t,r,s);
  restPose(float32(matrix,'node transform'));return {t,r,s,matrix};
}
export function gltfSkeleton(source,sceneIndex,scale){
  const json=source.json,nodes=gltfArray(json,'nodes'),meshes=gltfArray(json,'meshes'),skins=gltfArray(json,'skins'),scenes=gltfArray(json,'scenes'),parent=new Int32Array(nodes.length).fill(-1),poses=nodes.map(nodePose);
  for(const [i,node] of nodes.entries())for(const child of gltfArray(node,'children')){gltfRef(child,nodes,'node child');if(child===i||parent[child]!==-1)throw new Error('glTF node hierarchy has a cycle or multiple parents');parent[child]=i;}
  const roots=Array.from(parent,(_,i)=>i).filter(i=>parent[i]<0),topology=[],stack=roots.slice().reverse();
  while(stack.length){const i=stack.pop();topology.push(i);stack.push(...gltfArray(nodes[i],'children').slice().reverse());}
  if(topology.length!==nodes.length)throw new Error('glTF node hierarchy contains a cycle');
  const chosen=scenes.length?scenes[gltfRef(sceneIndex,scenes,'scene')]:undefined,sceneRoots=chosen?gltfArray(chosen,'nodes'):roots;
  if(!scenes.length&&sceneIndex!==0)throw new Error('Invalid glTF scene');
  if(new Set(sceneRoots).size!==sceneRoots.length)throw new Error('Duplicate glTF scene root');
  const active=new Set(),pending=sceneRoots.slice();while(pending.length){const i=gltfRef(pending.pop(),nodes,'scene root');if(!active.has(i)){active.add(i);pending.push(...gltfArray(nodes[i],'children'));}}
  for(const i of sceneRoots)if(parent[i]!==-1)throw new Error('glTF scene roots must have no parent');
  const meshNodes=[...active].filter(i=>nodes[i].mesh!==undefined),needed=new Set();
  const need=i=>{for(let at=i;at>=0&&!needed.has(at);at=parent[at])needed.add(at);};
  for(const i of active)if(nodes[i].camera!==undefined||nodes[i].extensions?.KHR_lights_punctual)throw new Error('Unsupported glTF camera/light in selected model scene');
  for(const i of meshNodes){gltfRef(nodes[i].mesh,meshes,'mesh');need(i);
    if(nodes[i].skin!==undefined){const skin=skins[gltfRef(nodes[i].skin,skins,'skin')],joints=gltfArray(skin,'joints');if(!joints.length||new Set(joints).size!==joints.length)throw new Error('Invalid glTF skin joints');
      for(const joint of joints){gltfRef(joint,nodes,'joint');if(!active.has(joint))throw new Error('glTF skin joint is outside selected scene');need(joint);}
      if(skin.skeleton!==undefined){const root=gltfRef(skin.skeleton,nodes,'skin skeleton');for(const joint of joints){let at=joint;while(at>=0&&at!==root)at=parent[at];if(at!==root)throw new Error('Invalid glTF skeleton root');}}
    }
  }
  for(const animation of gltfArray(json,'animations'))for(const channel of gltfArray(animation,'channels')){const i=gltfRef(channel.target?.node,nodes,'animation target');if(active.has(i))need(i);}
  if(!meshNodes.length)throw new Error('Selected glTF scene contains no mesh');
  const order=topology.filter(i=>needed.has(i));if(order.length>128)throw new Error('glTF skeleton exceeds pinned renderer bone capacity (128)');
  const boneOf=new Map(order.map((node,i)=>[node,i])),world=new Map();for(const i of topology)if(needed.has(i))world.set(i,parent[i]<0?poses[i].matrix:mul(world.get(parent[i]),poses[i].matrix));
  const bind=new Map();
  for(const i of meshNodes){if(nodes[i].skin===undefined)continue;const skin=skins[nodes[i].skin],joints=skin.joints;let ibm;
    if(skin.inverseBindMatrices!==undefined){ibm=readGltfAccessor(source,skin.inverseBindMatrices);if(ibm.type!=='MAT4'||ibm.componentType!==5126||ibm.normalized||ibm.count<joints.length)throw new Error('Invalid glTF inverse bind accessor');}
    joints.forEach((joint,k)=>{const value=ibm?invert(ibm.data.subarray(k*16,k*16+16)):ident();if(!value||!Array.from(value).every(Number.isFinite))throw new Error('glTF inverse bind matrix is singular');
      if(bind.has(joint)&&float32(value,'bind matrix').some((v,k)=>v!==Math.fround(bind.get(joint)[k])))throw new Error('Conflicting glTF shared-joint bind matrices cannot be represented');bind.set(joint,value);});
  }
  for(const i of order)if(!bind.has(i))bind.set(i,world.get(i));
  const bones=order.map((node,i)=>{const p=parent[node],inverse=p<0?undefined:invert(bind.get(p));if(p>=0&&!inverse)throw new Error('Singular glTF parent bind matrix');const local=p<0?Float64Array.from(bind.get(node)):mul(inverse,bind.get(node));for(const k of [12,13,14])local[k]*=scale;
    const matrix=float32(local,'bind matrix');if(matrix[3]!==0||matrix[7]!==0||matrix[11]!==0||matrix[15]!==1)throw new Error('Unsupported glTF perspective bind matrix');
    return {name:gltfName(nodes[node].name,`Bone ${i+1}`),parent:p<0?-1:boneOf.get(p),matrix};});validateBindHierarchy(bones);
  // parseSkeleton must accept every local bind record before it can build inverses.
  for(const bone of bones){const m=bone.matrix,det=m[0]*(m[5]*m[10]-m[6]*m[9])-m[4]*(m[1]*m[10]-m[2]*m[9])+m[8]*(m[1]*m[6]-m[2]*m[5]);if(Math.max(Math.abs(m[0]*m[5]-m[4]*m[1]),Math.abs(det))<=1e-9)throw new Error('glTF local bind is not invertible by pinned skeleton parser');}
  return {nodes,meshes,skins,parent,active,order,boneOf,poses,world,bind,bones,meshNodes,sceneIndex};
}
