import { readClipModel,validateClipPoses } from './model-clips.mjs';
import { writeMdlDoc } from './vendor/mdl-codec.mjs';
import { restMatrix } from './model-math.mjs';
import { readBoneKeyMetadata,patchBoneKeyRecord } from './bone-key-metadata.mjs';

function frameIndex(frame,count) {
 if(!Number.isInteger(frame)||frame<0||frame>count)throw new Error('Bone key frame is outside the selected clip');
 return frame;
}
function selection(bytes,options) {
 if(!options||typeof options!=='object')throw new Error('Expected bone key options');
 const model=readClipModel(bytes),{clip,bone}=options;
 if(!Number.isInteger(clip)||clip<0||clip>0xffffffff)throw new Error('Invalid animation clip ID');
 const animation=model.clips.find(value=>value.id===clip);
 if(!animation)throw new Error('Animation clip was not found');
 if(!Number.isInteger(bone)||bone<0||bone>=model.bones.length)throw new Error('Invalid key bone index');
 return {model,animation,bone:model.bones[bone],track:animation.tracks[bone].data};
}
function sample(track,left,right,frame,component) {
 // Endpoint reads retain source Float32 bits, including signed zero and multi-turn Euler angles.
 if(frame===left||frame===right)return track[frame*9+component];
 const start=track[left*9+component],end=track[right*9+component],fraction=(frame-left)/(right-left);
 // Pinned native sampling uses weighted translation/scale and wrapped Euler delta.
 // These algebraically equivalent lerps have different cancellation and signed-zero bits.
 if(component<3||component>=6)return Math.fround(start*(1-fraction)+end*fraction);
 let delta=end-start;
 if(delta>Math.PI)delta-=2*Math.PI;else if(delta< -Math.PI)delta+=2*Math.PI;
 return Math.fround(start+delta*fraction);
}
function intervalFits(track,left,right) {
 for(let frame=left+1;frame<right;frame++)for(let component=0;component<9;component++)if(!Object.is(sample(track,left,right,frame,component),track[frame*9+component]))return false;
 return true;
}
function stateOf({bone,animation,track}) {
 const metadata=readBoneKeyMetadata(bone.meta),record=metadata.records?.get(String(animation.id));
 if(metadata.kind==='unsupported')return {kind:'unsupported',keys:[],reason:metadata.reason};
 if(!record)return {kind:'unmanaged',keys:[]};
 const keys=record.keys;
 if(record.frameCount!==animation.frameCount)return {kind:'stale',keys,reason:'Bone key frameCount is out of sync with the current clip'};
 for(let i=1;i<keys.length;i++)if(!intervalFits(track,keys[i-1],keys[i]))return {kind:'stale',keys,reason:'Bone key interpolation does not recreate current dense samples'};
 return {kind:'managed',keys};
}
export function inspectBoneKeys(bytes,options) {
 const selected=selection(bytes,options),{animation,track}=selected,frame=frameIndex(options.frame??0,animation.frameCount);
 return {...stateOf(selected),frame,pose:Array.from(track.subarray(frame*9,frame*9+9)),fps:animation.fps,frameCount:animation.frameCount};
}
function poseValues(pose) {
 if(!Array.isArray(pose)||pose.length!==9||!pose.every(Number.isFinite))throw new Error('Expected nine finite local pose components');
 const values=Float32Array.from(pose);
 for(let i=0;i<9;i++){
  if(!Number.isFinite(values[i]))throw new Error('Pose component overflows Float32');
  if(values[i]===0&&pose[i]!==0)throw new Error('Pose component underflows Float32');
 }
 restMatrix(Array.from(values));return values;
}
function reducedKeys(track,count) {
 const keys=[0],pending=[[0,count]];
 while(pending.length){
  const [left,right]=pending.pop();
  if(intervalFits(track,left,right))keys.push(right);
  else {const middle=Math.floor((left+right)/2);pending.push([middle,right],[left,middle]);}
 }
 return keys;
}
function editKeys(track,keys,operation,count) {
 const frame=frameIndex(operation.frame,count),index=keys.indexOf(frame),type=operation.type;
 if(type==='add'){
  if(index!==-1)throw new Error('A bone key already occupies this frame');
  keys.push(frame);
 } else {
  if(index===-1)throw new Error('The selected frame is not an authored bone key');
  if(type==='set')track.set(poseValues(operation.pose),frame*9);
  else {
   if(type!=='duplicate'&&(frame===0||frame===count))throw new Error('Endpoint anchor keys cannot be moved or removed');
   if(type==='remove')keys.splice(index,1);
   else {
    const to=frameIndex(operation.to,count);
    if(keys.includes(to))throw new Error('A bone key already occupies the destination frame');
    track.set(track.slice(frame*9,frame*9+9),to*9);keys.push(to);
    if(type==='move')keys.splice(index,1);
   }
  }
 }
 keys.sort((a,b)=>a-b);
 for(let i=1;i<keys.length;i++)for(let f=keys[i-1]+1;f<keys[i];f++)for(let c=0;c<9;c++)track[f*9+c]=sample(track,keys[i-1],keys[i],f,c);
 return keys;
}
/** Immutable transaction; metadata alone never replaces the dense playback authority. */
export function editBoneKeys(bytes,operation) {
 const selected=selection(bytes,operation),{model,animation,bone,track}=selected,state=stateOf(selected),type=operation.type;
 if(state.kind==='unsupported')throw new Error(state.reason);
 let keys;
 if(type==='forget')bone.meta=patchBoneKeyRecord(bone.meta,animation.id,null);
 else {
  if(type==='adopt'){
   keys=Array.from({length:animation.frameCount+1},(_,frame)=>frame);
  } else {
   if(!['add','set','remove','move','duplicate','reduce'].includes(type))throw new Error('Unsupported bone key operation');
   if(state.kind!=='managed')throw new Error(state.kind==='stale'?'Bone key map is stale; explicitly adopt or forget it':'Adopt current samples before managed bone key editing');
   keys=type==='reduce'?reducedKeys(track,animation.frameCount):editKeys(track,[...state.keys],operation,animation.frameCount);
  }
  bone.meta=patchBoneKeyRecord(bone.meta,animation.id,{frameCount:animation.frameCount,keys});
 }
 const result=writeMdlDoc(model.doc),verified=readClipModel(result),verifiedAnimation=verified.clips.find(value=>value.id===animation.id);
 validateClipPoses(result,verifiedAnimation);
 if(type!=='forget'&&stateOf({bone:verified.bones[operation.bone],animation:verifiedAnimation,track:verifiedAnimation.tracks[operation.bone].data}).kind!=='managed')throw new Error('Bone key bake failed exact dense sample verification');
 return result;
}
