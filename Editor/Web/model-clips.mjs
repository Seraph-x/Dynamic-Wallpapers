import { readMdlDoc, writeMdlDoc } from './vendor/mdl-codec.mjs';
import { validateTables } from './model-tables.mjs';
import { restPose, validateBindHierarchy } from './model-math.mjs';
import { inspectModel } from './model.mjs';
import { validateGltfPoses } from './gltf-pose-validation.mjs';
import { readEventMetadata } from './event-json.mjs';
import { syncBoneKeyClips } from './bone-key-metadata.mjs';

// These are the pinned codec's header discovery limits, including subsequent
// headers scanned through the preceding clip's opaque trailer.
const MAX_CLIPS=256, MAX_FRAMES=100000, MAX_NAME=64, MAX_FPS=240;
const modes=new Set(['loop','mirror','single']);
const equal=(a,b)=>a.length===b.length&&a.every((value,i)=>value===b[i]);
const uint32=value=>Number.isInteger(value)&&value>=0&&value<=0xffffffff;
const utf8=new TextEncoder(),text=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true});

function read(bytes) {
 if(!(bytes instanceof Uint8Array))throw new Error('Expected MDL bytes');
 const doc=readMdlDoc(bytes);
 if(doc.raw||!doc.meshes||!equal(writeMdlDoc(doc),bytes))throw new Error('Unsupported or incomplete MDL layout');
 const skeletons=doc.sections.filter(section=>section.type==='MDLS');
 if(skeletons.length!==1||!skeletons[0].bones?.length)throw new Error('Expected one readable skeleton section');
 const bones=skeletons[0].bones;
 validateTables(doc,bones);validateBindHierarchy(bones);
 for(const bone of bones)restPose(bone.matrix);
 const section=doc.sections.find(section=>section.type==='MDLA'),clips=section?.anims??[],ids=new Set();
 for(const clip of clips){
  if(!uint32(clip.id)||ids.has(clip.id))throw new Error('Invalid or duplicate animation ID');ids.add(clip.id);
  if(typeof clip.name!=='string'||typeof clip.mode!=='string')throw new Error('Unsupported animation header encoding');
  timing(clip);
 }
 return {doc,bones,section,clips};
}
function timing({fps,frameCount}) {
 if(!(Number.isFinite(fps)&&fps>0&&fps<=MAX_FPS)||!Number.isInteger(frameCount)||frameCount<1||frameCount>0xffffffff)throw new Error('Invalid animation timing');
 const duration=Math.fround(frameCount/fps);
 if(!Number.isFinite(duration)||duration<=0)throw new Error('Animation timing is not representable in Float32');
}
function name(value) {
 if(typeof value!=='string'||!value||value.length>MAX_NAME||value.includes('\0')||text.decode(utf8.encode(value))!==value)throw new Error('Animation name must contain 1..64 valid characters');
 return value;
}
function settings(operation,previous) {
 const next={name:operation.name??previous?.name,fps:operation.fps??previous?.fps,frameCount:operation.frameCount??previous?.frameCount,mode:operation.mode??previous?.mode};
 for(const key of ['name','fps','frameCount','mode'])if(Object.hasOwn(operation,key)&&operation[key]===null)throw new Error(`Invalid animation ${key}`);
 if(!previous||next.name!==previous.name)name(next.name);
 if(!previous||next.mode!==previous.mode)if(!modes.has(next.mode))throw new Error('Unsupported animation mode');
 if(!previous||next.frameCount!==previous.frameCount)if(!Number.isInteger(next.frameCount)||next.frameCount<1||next.frameCount>MAX_FRAMES)throw new Error('Animation frameCount must be 1..100000 for the pinned reader');
 if(!Number.isFinite(next.fps)||next.fps<=0||next.fps>MAX_FPS)throw new Error('Animation FPS must be finite and in (0,240]');
 next.fps=Math.fround(next.fps);timing(next);return next;
}
export function inspectClips(bytes) {
 const {clips}=read(bytes);
 return {clips:clips.map(({id,name,fps,frameCount,mode})=>({id,name,fps,frameCount,mode,duration:frameCount/fps})),defaultId:clips[0]?.id??null};
}
function nextID(clips) {
 const ids=new Set(clips.map(clip=>clip.id));let id=1;
 while(ids.has(id))id++;
 return id;
}
function requireCapacity(clips) {
 if(clips.length>=MAX_CLIPS)throw new Error('The pinned reader supports at most 256 animation clips');
}
function newClip(model,operation) {
 requireCapacity(model.clips);const values=settings(operation),id=nextID(model.clips);
 const tracks=model.bones.map(bone=>{
  const pose=restPose(bone.matrix),data=new Float32Array((values.frameCount+1)*9);
  for(let frame=0;frame<=values.frameCount;frame++)data.set(pose,frame*9);
  return {boneId:0,data};
 });
 return {id,unk0:0,unk1:0,...values,tracks,prefix:new Uint8Array(31),events:[]};
}
function resizeTrack(track,oldCount,newCount) {
 const data=new Float32Array((newCount+1)*9);
 for(let frame=0;frame<=newCount;frame++){
  if(frame===0||frame===newCount){data.set(track.data.subarray(frame===0?0:oldCount*9,frame===0?9:(oldCount+1)*9),frame*9);continue;}
  const time=frame*oldCount/newCount,left=Math.floor(time),right=Math.min(left+1,oldCount),fraction=time-left;
  for(let component=0;component<9;component++){
   const start=track.data[left*9+component],end=track.data[right*9+component];let delta=end-start;
   if(component>=3&&component<=5){if(delta>Math.PI)delta-=2*Math.PI;else if(delta< -Math.PI)delta+=2*Math.PI;}
   data[frame*9+component]=start+delta*fraction;
  }
 }
 return {...track,data};
}
function retimeEvents(clip,next) {
 return clip.events.map(event=>{
  const metadata=readEventMetadata(event,clip);
  if(metadata.frame>next.frameCount)throw new Error('Resize would exclude an animation event');
  const time=Math.fround(metadata.frame/next.fps);
  if(!Number.isFinite(time))throw new Error('Animation event timing overflows Float32');
  return {...event,time};
 });
}
function updateClip(clip,operation) {
 const values=settings(operation,clip),timingChanged=values.frameCount!==clip.frameCount||values.fps!==clip.fps;
 return {...clip,...values,
  tracks:values.frameCount===clip.frameCount?clip.tracks:clip.tracks.map(track=>resizeTrack(track,clip.frameCount,values.frameCount)),
  events:timingChanged?retimeEvents(clip,values):clip.events};
}
function deleteClip(model,clip,operation) {
 if(!Array.isArray(operation.referenced)||operation.referenced.some(id=>!uint32(id)))throw new Error('Deletion requires readable explicit animation references');
 if(operation.referenced.includes(clip.id))throw new Error('Animation is explicitly referenced by a scene layer');
 const remaining=model.clips.filter(candidate=>candidate!==clip);
 if(clip===model.clips[0]&&remaining.length){
  const index=remaining.findIndex(candidate=>candidate.id===operation.replacement);
  if(index<0)throw new Error('Deleting the default animation requires an explicit surviving replacement');
  remaining.unshift(...remaining.splice(index,1));
 } else if(operation.replacement!==undefined)throw new Error('Default replacement is only valid when deleting the first of multiple clips');
 return remaining;
}
function validatePoses(bytes,clip) {
 const model=inspectModel(bytes);
 const meshes=model.meshes.map(mesh=>{if(mesh.error)throw new Error(mesh.error);return {...mesh,boneIdx:mesh.joints};});
 validateGltfPoses({bones:model.bones,meshes,animations:clip?[{...clip,tracks:clip.tracks.map(track=>track.data)}]:[]});
}
export { read as readClipModel,validatePoses as validateClipPoses };
/** Pure transaction: parsing owns all buffers, and failures never mutate input. */
export function editModelClips(bytes,operation) {
 if(!operation||typeof operation!=='object')throw new Error('Expected an animation operation');
 const model=read(bytes);let clip,id;
 if(operation.type==='create'){
  clip=newClip(model,operation);model.clips.push(clip);id=clip.id;
  syncBoneKeyClips(model.bones,{type:'create',id});
 } else {
  if(!uint32(operation.id))throw new Error('Invalid animation ID');
  const index=model.clips.findIndex(clip=>clip.id===operation.id),source=model.clips[index];
  if(!source)throw new Error('Animation ID was not found');id=source.id;
  if(operation.type==='duplicate'){
   requireCapacity(model.clips);clip={...source,id:nextID(model.clips),name:name(operation.name)};model.clips.push(clip);id=clip.id;
   syncBoneKeyClips(model.bones,{type:'duplicate',id,sourceID:source.id});
  } else if(operation.type==='update'){
   clip=updateClip(source,operation);model.clips[index]=clip;
  } else if(operation.type==='delete'){model.clips=deleteClip(model,source,operation);syncBoneKeyClips(model.bones,{type:'delete',id});}
  else throw new Error('Unsupported animation operation');
 }
 if(model.section)model.section.anims=model.clips;
 else {
  const section={type:'MDLA',version:'0006',b8:0,anims:model.clips},bind=model.doc.sections.findIndex(section=>section.type==='MDLE');
  model.doc.sections.splice(bind<0?model.doc.sections.length:bind,0,section);
 }
 const result=writeMdlDoc(model.doc),verified=read(result);
 if(!equal(writeMdlDoc(verified.doc),result))throw new Error('Edited animation failed lossless verification');
 validatePoses(result,clip);
 return {bytes:result,id};
}
