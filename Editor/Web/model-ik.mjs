import { readClipModel,validateClipPoses } from './model-clips.mjs';
import { writeMdlDoc } from './vendor/mdl-codec.mjs';
import { mul } from './vendor/gltf-math.mjs';
import { restMatrix } from './model-math.mjs';
import { add,sub,scale,dot,length,unit,identity,multiply,transpose,rotation,align,eulerNear,elbow } from './model-ik-math.mjs';

function float32(value,label){
 if(!Number.isFinite(value))throw new Error(`${label} must be finite`);
 const encoded=Math.fround(value);
 if(!Number.isFinite(encoded))throw new Error(`${label} overflows Float32`);
 if(encoded===0&&value!==0)throw new Error(`${label} underflows Float32`);
 return encoded;
}
function vector(value,label){
 if(!Array.isArray(value)||value.length!==3)throw new Error(`IK ${label} requires three finite Float32 components`);
 return Array.from(value,(v,i)=>float32(v,`IK ${label} ${i}`));
}
function selection(bytes,options){
 if(!options||typeof options!=='object'||Array.isArray(options))throw new Error('Expected IK options');
 const model=readClipModel(bytes),{clip,bone}=options;
 if(!Number.isInteger(clip)||clip<0||clip>0xffffffff)throw new Error('Invalid IK animation clip ID');
 const animation=model.clips.find(a=>a.id===clip);
 if(!animation)throw new Error('IK animation clip was not found');
 if(!Number.isInteger(bone)||bone<0||bone>=model.bones.length)throw new Error('Invalid IK bone index');
 const middle=model.bones[bone].parent,root=model.bones[middle]?.parent;
 if(middle<0||root===undefined||root<0)throw new Error('IK tip bone requires a direct parent and grandparent chain');
 return {model,animation,root,middle,tip:bone};
}
function frameIndex(animation,frame){
 if(!Number.isInteger(frame)||frame<0||frame>animation.frameCount)throw new Error('IK sample frame is outside the selected clip range');
 return frame;
}
const local=(animation,bone,frame)=>Array.from(animation.tracks[bone].data.subarray(frame*9,frame*9+9));
function hierarchy(context,frame,replacements=new Map()){
 const matrices=[],rotations=[];
 for(const [i,bone] of context.model.bones.entries()){
  const pose=replacements.get(i)??local(context.animation,i,frame),matrix=restMatrix(pose),parent=bone.parent;
  matrices.push(parent<0?matrix:Float32Array.from(mul(matrices[parent],matrix)));
  rotations.push(parent<0?rotation(pose):multiply(rotations[parent],rotation(pose)));
  if(!matrices[i].every(Number.isFinite))throw new Error('IK world hierarchy overflows Float32');
 }
 return {matrices,rotations,positions:[context.root,context.middle,context.tip].map(i=>Array.from(matrices[i].subarray(12,15)))};
}
function supportedScales(context,frame){
 for(let i=context.middle;i>=0;i=context.model.bones[i].parent){
  const s=local(context.animation,i,frame).slice(6);
  if(s.some(v=>v<=0))throw new Error(`IK bone ${i} requires positive local scales`);
  if(i!==context.middle&&(s[0]!==s[1]||s[1]!==s[2]))throw new Error(`IK root and ancestors require positive uniform scales (bone ${i})`);
 }
}
function suggestedPole(positions){
 const [a,b,c]=positions,axis=sub(c,a),n=length(axis)?unit(axis):unit(sub(b,a));
 const bend=sub(sub(b,a),scale(n,dot(sub(b,a),n))),total=length(sub(b,a))+length(sub(c,b));
 if(length(bend)>64*Number.EPSILON*total)return add(a,scale(unit(bend),total));
 const basis=[[0,1,0],[1,0,0],[0,0,1]].sort((x,y)=>Math.abs(dot(x,n))-Math.abs(dot(y,n)))[0];
 return add(a,scale(unit(sub(basis,scale(n,dot(basis,n)))),total));
}
export function inspectIkChain(bytes,options){
 const context=selection(bytes,options),frame=frameIndex(context.animation,options.frame);
 const {positions}=hierarchy(context,frame);
 if(!length(sub(positions[1],positions[0]))||!length(sub(positions[2],positions[1])))throw new Error('IK chain has a zero-length segment');
 const {root,middle,tip,animation}=context;
 return {root,middle,tip,positions,pole:suggestedPole(positions),fps:animation.fps,frameCount:animation.frameCount,mode:animation.mode};
}
function encodedRotation(original,angles){
 const delta=[0,0,0,0,0,0,1,1,1],pose=original.slice();
 for(let i=0;i<3;i++){
  const difference=angles[i]-original[i+3];
  // Exact identity components retain their source bits, including signed zero.
  if(Math.abs(difference)<=32*Number.EPSILON*Math.max(1,Math.abs(original[i+3])))continue;
  delta[i+3]=float32(difference,`IK rotation delta ${i}`);
  pose[i+3]=float32(original[i+3]+delta[i+3],`IK saved Euler ${i}`);
 }
 return {delta,pose};
}
function solveSample(context,frame,target,pole,previous,preserveDefault){
 supportedScales(context,frame);
 const source=hierarchy(context,frame),geometry=elbow(source.positions,target,pole),replacements=new Map(),poses=[];
 // Default geometry is an exact identity operation. Re-solving its rounded
 // world positions can otherwise perturb an unchanged native Euler by one ULP.
 // Check both explicit coordinates, so changing only the pole still solves.
 // Once this range changes a sample, later defaults must follow its Euler
 // continuity rather than restoring an arbitrary source rotation branch.
 const defaultPole=suggestedPole(source.positions).map(Math.fround);
 if(preserveDefault&&target.every((v,i)=>v===source.positions[2][i])&&pole.every((v,i)=>v===defaultPole[i])){
  for(const bone of [context.root,context.middle]){
   replacements.set(bone,local(context.animation,bone,frame));
   poses.push({bone,delta:[0,0,0,0,0,0,1,1,1]});
  }
  return {preview:{poses,positions:source.positions,residual:0},replacements};
 }
 for(const [joint,from,to] of [[context.root,sub(source.positions[1],source.positions[0]),sub(geometry.point,source.positions[0])],[context.middle,null,null]]){
  const current=joint===context.root?source:hierarchy(context,frame,replacements),parent=context.model.bones[joint].parent;
  const start=from??sub(current.positions[2],current.positions[1]),finish=to??sub(target,current.positions[1]);
  const world=multiply(align(start,finish,geometry.normal),current.rotations[joint]);
  const localRotation=multiply(transpose(parent<0?identity:current.rotations[parent]),world),original=local(context.animation,joint,frame);
  const angles=eulerNear(localRotation,previous?.get(joint)??original.slice(3,6)),encoded=encodedRotation(original,angles);
  replacements.set(joint,encoded.pose);poses.push({bone:joint,delta:encoded.delta});
 }
 const {positions}=hierarchy(context,frame,replacements),residual=length(sub(positions[2],target));
 if(!Number.isFinite(residual)||residual>1e-5*geometry.total)throw new Error(`IK native Float32 endpoint residual ${residual} exceeds tolerance ${1e-5*geometry.total}`);
 return {preview:{poses,positions,residual},replacements};
}
/** Inclusive sample bake. Each solve reads its untouched source frame; only
 * Euler continuity references the previous encoded candidate sample. Parsing
 * owns the clip, so completed frames can be stored without retaining a range. */
export function bakeTwoBoneIk(bytes,options){
 const context=selection(bytes,options),{animation}=context,start=frameIndex(animation,options.start),end=frameIndex(animation,options.end);
 if(start>end)throw new Error('IK sample range must be ordered');
 if(options.previewFrame!==undefined){frameIndex(animation,options.previewFrame);if(options.previewFrame<start||options.previewFrame>end)throw new Error('IK preview frame is outside the baked range');}
 const target=vector(options.target,'target'),pole=vector(options.pole,'pole');
 let previous,preview,modified=false;
 for(let frame=start;frame<=end;frame++){
  const result=solveSample(context,frame,target,pole,previous,!modified);
  previous=new Map([...result.replacements].map(([bone,pose])=>[bone,pose.slice(3,6)]));
  for(const [bone,pose] of result.replacements){
   const track=animation.tracks[bone].data;
   if(!modified)modified=pose.some((v,i)=>!Object.is(v,track[frame*9+i]));
   track.set(pose,frame*9);
  }
  if(frame===options.previewFrame)preview=result.preview;
 }
 const result=writeMdlDoc(context.model.doc),verified=readClipModel(result);
 validateClipPoses(result,verified.clips.find(c=>c.id===animation.id));
 return preview?{bytes:result,preview}:{bytes:result};
}
export function solveTwoBoneIk(bytes,options){
 // Single-sample solving has the same quantization and final transform
 // validation as baking. Range previews must instead consume bake.preview.
 if(!options||typeof options!=='object'||Array.isArray(options))throw new Error('Expected IK options');
 return bakeTwoBoneIk(bytes,{...options,start:options.frame,end:options.frame,previewFrame:options.frame}).preview;
}
