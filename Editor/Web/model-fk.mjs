import { readClipModel,validateClipPoses } from './model-clips.mjs';
import { restMatrix } from './model-math.mjs';
import { writeMdlDoc } from './vendor/mdl-codec.mjs';

function float32(value,label) {
 if(!Number.isFinite(value))throw new Error(`${label} must be finite`);
 const encoded=Math.fround(value);
 if(!Number.isFinite(encoded))throw new Error(`${label} overflows Float32`);
 if(encoded===0&&value!==0)throw new Error(`${label} underflows Float32`);
 return encoded;
}
function deltaValues(delta) {
 if(!Array.isArray(delta)||delta.length!==9)throw new Error('Expected nine finite local delta components');
 return Array.from(delta,(value,i)=>float32(value,`Delta component ${i}`));
}
function selection(model,{clip,bone,start,end}) {
 if(!Number.isInteger(clip)||clip<0||clip>0xffffffff)throw new Error('Invalid animation clip ID');
 const animation=model.clips.find(value=>value.id===clip);
 if(!animation)throw new Error('Animation clip was not found');
 if(!Number.isInteger(bone)||bone<0||bone>=model.bones.length)throw new Error('Invalid FK bone index');
 if(!Number.isInteger(start)||!Number.isInteger(end)||start<0||end<start||end>animation.frameCount)throw new Error('FK sample range is outside the selected clip');
 return animation;
}
/** Add local translation/XYZ radians and multiply signed local scale, matching
 * pinned setBonePose's Float32 delta and accumulator. Range is inclusive. */
export function bakeBoneDelta(bytes,operation) {
 if(!operation||typeof operation!=='object'||Array.isArray(operation))throw new Error('Expected FK delta options');
 const model=readClipModel(bytes),animation=selection(model,operation),delta=deltaValues(operation.delta);
 const track=animation.tracks[operation.bone].data;
 for(let frame=operation.start;frame<=operation.end;frame++){
  const pose=Array.from(track.subarray(frame*9,frame*9+9));
  for(let i=0;i<9;i++){
   // Retain the original bits for identity components, including signed zero.
   if(delta[i]===(i<6?0:1))continue;
   pose[i]=float32(i<6?pose[i]+delta[i]:pose[i]*delta[i],`FK result component ${i} at sample ${frame}`);
  }
  restMatrix(pose);track.set(pose,frame*9);
 }
 const result=writeMdlDoc(model.doc),verified=readClipModel(result);
 validateClipPoses(result,verified.clips.find(clip=>clip.id===animation.id));
 return result;
}
