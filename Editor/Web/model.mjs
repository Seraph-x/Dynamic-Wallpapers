import { readMdlDoc, writeMdlDoc, meshVertexLayout } from './vendor/mdl-codec.mjs';
import { restPose } from './model-math.mjs';
import { validateTables, remapSkeletonTail, remapBindPose } from './model-tables.mjs';

const view=bytes=>new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
const equalBytes=(a,b)=>a.length===b.length && a.every((v,i)=>v===b[i]);
const index=(v,length)=>Number.isInteger(v) && v>=0 && v<length;
function name(value) {
  if(typeof value!=='string' || value.includes('\0') || new TextDecoder().decode(new TextEncoder().encode(value))!==value) throw new Error('Invalid bone name');
  return value;
}
function readModel(bytes) {
  if(!(bytes instanceof Uint8Array))throw new Error('Expected MDL bytes');
  let doc;
  try {doc=readMdlDoc(bytes);}catch(error){throw new Error('Invalid MDL resource',{cause:error});}
  if(doc.raw || !doc.meshes || !equalBytes(writeMdlDoc(doc),bytes))throw new Error('Unsupported or incomplete MDL layout');
  const skeletons=doc.sections.filter(s=>s.type==='MDLS');
  if(skeletons.length!==1 || !skeletons[0].bones?.length)throw new Error('Expected one readable skeleton section');
  return {doc,skeleton:skeletons[0]};
}
function skinLayout(mesh) {
  // These are the fields understood by the pinned codec. Unrecognized bits can
  // change offsets; deriving a plausible stride is insufficient for authoring.
  const known=2|4|8|32|65536|8388608|16777216|1;
  if(!Number.isInteger(mesh.meshFlag) || (mesh.meshFlag & ~known)!==0)throw new Error('Unsupported vertex layout');
  const layout=meshVertexLayout(mesh.meshFlag);
  if(layout.bone<0 || layout.weight<0 || mesh.vertexData.length%layout.stride!==0)throw new Error('Unsupported skinned vertex layout');
  return {...layout,count:mesh.vertexData.length/layout.stride};
}
function destinationBones(input,previous) {
  if(!Array.isArray(input) || !input.length)throw new Error('A skeleton must contain bones');
  if(input.length>1024)throw new Error('The pinned renderer supports at most 1024 bones');
  const map=Array(previous.length).fill(-1),sources=[];
  const bones=input.map((bone,i)=>{
    if(!bone || Object.keys(bone).some(k=>!['source','parent','name','matrix'].includes(k)) || !Number.isInteger(bone.parent) || bone.parent< -1 || bone.parent>=i)throw new Error('Parents must precede children; cycles are invalid');
    sources.push(bone.source);
    if(bone.source===null){
      const pose=restPose(bone.matrix);
      return {name:name(bone.name),parent:bone.parent,matrix:Float32Array.from(bone.matrix),head0:1,meta:'',pose};
    }
    if(!index(bone.source,previous.length) || map[bone.source]!==-1 || bone.matrix!==undefined)throw new Error('Invalid or duplicate bone source');
    map[bone.source]=i;
    return {...previous[bone.source],name:bone.name===undefined?previous[bone.source].name:name(bone.name),parent:bone.parent};
  });
  return {bones,map,sources};
}
function replacementResolver(map,replacements={}) {
  if(!replacements || typeof replacements!=='object' || Array.isArray(replacements))throw new Error('Invalid bone replacements');
  return (source,needed=true)=>{
    if(!index(source,map.length))throw new Error('Invalid source bone reference');
    if(map[source]>=0)return map[source];
    if(Object.hasOwn(replacements,String(source)))return replacements[source];
    if(!needed)return 0;
    throw new Error(`Deleted bone ${source} requires an explicit replacement`);
  };
}
function validateReplacements(replacements,map,length) {
  for(const [key,value] of Object.entries(replacements))if(!/^(0|[1-9]\d*)$/.test(key) || !index(Number(key),map.length) || map[Number(key)]!==-1 || !index(value,length))throw new Error('Invalid bone replacement');
}
function remapSkin(mesh,previousCount,resolve) {
  const layout=skinLayout(mesh),dv=view(mesh.vertexData);
  for(let vertex=0;vertex<layout.count;vertex++){
    let total=0;
    for(let slot=0;slot<4;slot++){
      const offset=vertex*layout.stride,source=dv.getUint32(offset+layout.bone+slot*4,true),weight=dv.getFloat32(offset+layout.weight+slot*4,true);
      if(!index(source,previousCount) || !Number.isFinite(weight) || weight<0)throw new Error('Invalid skin joint or weight');
      total+=weight;dv.setUint32(offset+layout.bone+slot*4,resolve(source,weight>0),true);
    }
    if(!(total>0))throw new Error('Skin vertex has zero total weight');
  }
}
function requireBoneCapacity(limit,count) {
  // The pinned renderer has a 128-uniform hard ceiling and can compile a
  // smaller palette on a particular GPU. Authoring must not silently truncate.
  if(!Number.isInteger(limit) || limit<1 || limit>128)throw new Error('A verified target GPU bone capacity (1..128) is required');
  if(count>limit)throw new Error(`Skeleton exceeds the target GPU bone capacity (${limit})`);
}
/** Pure resource transaction. Existing local transforms/tracks retain their
 * values when reparented; this API does not bake world-space motion. */
export function rewriteSkeleton(bytes,{bones:input,replacements={},boneLimit}) {
  const {doc,skeleton}=readModel(bytes),previous=skeleton.bones;
  const {bones,map,sources}=destinationBones(input,previous);
  const resolve=replacementResolver(map,replacements);validateReplacements(replacements,map,bones.length);
  const structural=sources.length!==previous.length || sources.some((source,i)=>source!==i || bones[i].parent!==previous[i].parent);
  if(structural){
    requireBoneCapacity(boneLimit,bones.length);
    validateTables(doc,previous);
    previous.forEach((bone,i)=>{if(!Number.isInteger(bone.parent) || bone.parent< -1 || bone.parent>=i)throw new Error('Unsupported source skeleton hierarchy');});
    for(const mesh of doc.meshes)remapSkin(mesh,previous.length,resolve);
    for(const section of doc.sections){
      if(section.type==='MDAT')for(const attachment of section.attachments)attachment.bone=resolve(attachment.bone);
      if(section.type==='MDLA')for(const clip of section.anims)clip.tracks=sources.map((source,i)=>{
        if(source!==null)return clip.tracks[source];
        const data=new Float32Array((clip.frameCount+1)*9);
        for(let frame=0;frame<=clip.frameCount;frame++)data.set(bones[i].pose,frame*9);
        return {boneId:0,data};
      });
      if(section.type==='MDLE')section.data=remapBindPose(section.data,bones,sources);
    }
    skeleton.tail=remapSkeletonTail(skeleton.tail,previous,bones,sources,map);
  }
  skeleton.bones=bones.map(({pose,...bone})=>bone);
  const result=writeMdlDoc(doc);
  if(!equalBytes(writeMdlDoc(readMdlDoc(result)),result))throw new Error('Edited model failed lossless verification');
  return {bytes:result,oldToNew:map};
}
export function setSkinInfluences(bytes,{mesh:meshIndex,edits,boneLimit}) {
  const {doc,skeleton}=readModel(bytes);
  requireBoneCapacity(boneLimit,skeleton.bones.length);
  if(!index(meshIndex,doc.meshes.length) || !Array.isArray(edits))throw new Error('Invalid mesh or influence edits');
  const mesh=doc.meshes[meshIndex],layout=skinLayout(mesh),dv=view(mesh.vertexData),seen=new Set();
  for(const edit of edits){
    if(!edit || !index(edit.vertex,layout.count) || seen.has(edit.vertex) || !Array.isArray(edit.influences) || !edit.influences.length || edit.influences.length>4)throw new Error('Invalid or repeated skin vertex edit');
    seen.add(edit.vertex);const joints=new Set();
    for(const influence of edit.influences){
      if(!influence || !index(influence.joint,skeleton.bones.length) || joints.has(influence.joint) || !Number.isFinite(influence.weight) || influence.weight<0)throw new Error('Invalid or repeated skin influence');
      joints.add(influence.joint);
    }
    // Scaling by the largest value avoids overflow while normalizing valid weights.
    const largest=Math.max(...edit.influences.map(i=>i.weight));
    if(!largest)throw new Error('Skin weights must have a positive sum');
    const total=edit.influences.reduce((sum,i)=>sum+i.weight/largest,0),offset=edit.vertex*layout.stride;
    for(let slot=0;slot<4;slot++){
      const influence=edit.influences[slot];
      dv.setUint32(offset+layout.bone+slot*4,influence?.joint??0,true);
      dv.setFloat32(offset+layout.weight+slot*4,influence?influence.weight/largest/total:0,true);
    }
  }
  return writeMdlDoc(doc);
}
function inspectMesh(mesh,boneCount) {
  const layout=skinLayout(mesh),dv=view(mesh.vertexData),n=layout.count;
  if(!n)throw new Error('The mesh has no vertices');
  const positions=new Float32Array(n*3),joints=new Uint32Array(n*4),weights=new Float32Array(n*4);
  for(let i=0;i<n;i++){
    for(let k=0;k<3;k++)positions[i*3+k]=dv.getFloat32(i*layout.stride+k*4,true);
    let total=0;
    for(let k=0;k<4;k++){
      const j=i*4+k;joints[j]=dv.getUint32(i*layout.stride+layout.bone+k*4,true);weights[j]=dv.getFloat32(i*layout.stride+layout.weight+k*4,true);
      if(joints[j]>=boneCount || !Number.isFinite(weights[j]) || weights[j]<0)throw new Error('Invalid mesh skin references');total+=weights[j];
    }
    if(!(total>0))throw new Error('A mesh vertex has zero total weight');
  }
  if(!positions.every(Number.isFinite))throw new Error('Invalid mesh positions');
  const step=n>65535?4:2,indices=new Uint32Array(mesh.indexData.length/step),iv=view(mesh.indexData);
  if(mesh.indexData.length%step || indices.length%3)throw new Error('Invalid mesh triangle layout');
  for(let i=0;i<indices.length;i++){indices[i]=step===4?iv.getUint32(i*step,true):iv.getUint16(i*step,true);if(indices[i]>=n)throw new Error('Mesh triangle index is out of range');}
  return {vertexCount:n,positions,indices,joints,weights};
}
export function inspectModel(bytes) {
  const {doc,skeleton}=readModel(bytes);
  skeleton.bones.forEach((bone,i)=>{if(!Number.isInteger(bone.parent)||bone.parent< -1||bone.parent>=i)throw new Error('Unsupported source skeleton hierarchy');});
  return {version:doc.version,bones:skeleton.bones,
    meshes:doc.meshes.map(mesh=>{try{return inspectMesh(mesh,skeleton.bones.length);}catch(error){return {error:String(error.message)};}}),
    attachments:doc.sections.filter(s=>s.type==='MDAT').flatMap(s=>s.attachments??[]),
    animations:doc.sections.filter(s=>s.type==='MDLA').flatMap(s=>s.anims??[])};
}
