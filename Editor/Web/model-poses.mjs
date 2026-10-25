import { readClipModel,validateClipPoses } from './model-clips.mjs';
import { writeMdlDoc } from './vendor/mdl-codec.mjs';
import { restPose,restMatrix } from './model-math.mjs';

function selection(bytes,{clip,bone}) {
 const model=readClipModel(bytes);
 if(!Number.isInteger(clip)||clip<0||clip>0xffffffff)throw new Error('Invalid animation clip ID');
 const animation=model.clips.find(value=>value.id===clip);
 if(!animation)throw new Error('Animation clip was not found');
 if(!Number.isInteger(bone)||bone<0||bone>=model.bones.length)throw new Error('Invalid pose bone index');
 return {model,animation,track:animation.tracks[bone].data,bone};
}
function frameIndex(animation,frame) {
 if(!Number.isInteger(frame)||frame<0||frame>animation.frameCount)throw new Error('Pose frame is outside the selected clip');
 return frame;
}
export function inspectBonePose(bytes,options) {
 const {animation,track,bone}=selection(bytes,options),frame=frameIndex(animation,options.frame);
 return {clip:animation.id,bone,frame,fps:animation.fps,frameCount:animation.frameCount,time:frame/animation.fps,pose:Array.from(track.subarray(frame*9,frame*9+9))};
}
function poseValues(pose) {
 if(!Array.isArray(pose)||pose.length!==9||!pose.every(Number.isFinite))throw new Error('Expected nine finite local pose components');
 const values=Float32Array.from(pose);
 if(values.some((value,i)=>value===0&&pose[i]!==0))throw new Error('Pose component underflows Float32');
 restMatrix(Array.from(values));return values;
}
/** Dense native samples: change only the requested bone and sample(s). */
export function editBonePose(bytes,operation) {
 const {model,animation,track,bone}=selection(bytes,operation);
 if(operation.type==='set'||operation.type==='reset'){
  const frame=frameIndex(animation,operation.frame),pose=operation.type==='reset'?Array.from(restPose(model.bones[bone].matrix)):operation.pose;
  track.set(poseValues(pose),frame*9);
 }else if(operation.type==='interpolate'){
  const start=frameIndex(animation,operation.start),end=frameIndex(animation,operation.end);
  if(end-start<2)throw new Error('Interpolation range requires at least one interior frame');
  const first=track.slice(start*9,start*9+9),last=track.slice(end*9,end*9+9);
  for(let frame=start+1;frame<end;frame++)for(let i=0;i<9;i++){
   let delta=last[i]-first[i];
   if(i>=3&&i<6){if(delta>Math.PI)delta-=2*Math.PI;else if(delta< -Math.PI)delta+=2*Math.PI;}
   track[frame*9+i]=first[i]+delta*(frame-start)/(end-start);
  }
 }else throw new Error('Unsupported pose operation');
 const result=writeMdlDoc(model.doc);
 readClipModel(result);validateClipPoses(result,animation);return result;
}
