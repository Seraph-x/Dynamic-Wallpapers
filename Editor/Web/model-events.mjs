import { writeMdlDoc } from './vendor/mdl-codec.mjs';
import { readClipModel } from './model-clips.mjs';
import { readEventMetadata, patchEventMetadata, validateEventFrame, validateEventName } from './event-json.mjs';

// readEventsExact in the pinned codec rejects larger event tables.
const MAX_EVENTS=4096;
function selectedClip(model,id) {
 if(!Number.isInteger(id)||id<0||id>0xffffffff)throw new Error('Invalid animation clip ID');
 const clip=model.clips.find(clip=>clip.id===id);
 if(!clip)throw new Error('Animation clip ID was not found');
 return clip;
}
export function inspectFrameEvents(bytes,clipID) {
 const clip=selectedClip(readClipModel(bytes),clipID);
 return {clip:clip.id,frameCount:clip.frameCount,fps:clip.fps,events:clip.events.map((event,index)=>{
  const entry={index,time:event.time,raw:event.json};
  try{return {...entry,...readEventMetadata(event,clip)};}
  catch(error){return {...entry,reason:error.message};}
 })};
}
function requireIndex(index,length) {
 if(!Number.isInteger(index)||index<0||index>=length)throw new Error('Animation event index is out of range');
 return index;
}
function requireCapacity(events) {
 if(events.length>=MAX_EVENTS)throw new Error('The pinned reader supports at most 4096 animation events');
}
function updatedEvent(event,clip,operation) {
 const previous=readEventMetadata(event,clip),changes={};
 if(Object.hasOwn(operation,'frame'))changes.frame=validateEventFrame(operation.frame,clip.frameCount);
 if(Object.hasOwn(operation,'name'))changes.name=validateEventName(operation.name);
 const frame=changes.frame??previous.frame;
 return {...event,json:patchEventMetadata(event.json,changes),time:frame===previous.frame?event.time:Math.fround(frame/clip.fps)};
}
/** Parsing owns all buffers; validation and failed edits never mutate the input. */
export function editFrameEvents(bytes,operation) {
 if(!operation||typeof operation!=='object')throw new Error('Expected an animation event operation');
 const model=readClipModel(bytes),clip=selectedClip(model,operation.clip),events=clip.events;
 if(operation.type==='add'){
  requireCapacity(events);
  const frame=validateEventFrame(operation.frame,clip.frameCount),name=validateEventName(operation.name);
  events.push({time:Math.fround(frame/clip.fps),json:JSON.stringify({frame,name})});
 } else {
  const index=requireIndex(operation.index,events.length);
  if(operation.type==='duplicate'){requireCapacity(events);events.splice(index+1,0,{...events[index]});}
  else if(operation.type==='update')events[index]=updatedEvent(events[index],clip,operation);
  else if(operation.type==='remove')events.splice(index,1);
  else if(operation.type==='move'){
   const to=requireIndex(operation.to,events.length),[event]=events.splice(index,1);events.splice(to,0,event);
  } else throw new Error('Unsupported animation event operation');
 }
 const result=writeMdlDoc(model.doc),verified=readClipModel(result),roundtrip=writeMdlDoc(verified.doc);
 if(!result.every((value,index)=>value===roundtrip[index])||result.length!==roundtrip.length)throw new Error('Edited animation events failed lossless verification');
 return result;
}
