import { gltfArray } from './gltf-source.mjs';
import { readGltfAccessor } from './gltf-accessors.mjs';
import { gltfRef,gltfName,quaternion,float32 } from './gltf-validation.mjs';
import { sampleAt,quatToEuler } from './vendor/gltf-math.mjs';
export function gltfAnimations(source,skeleton,{fps,scale,mode}){
  const animations=[],info=[];let omitted=0;
  for(const [ai,animation] of gltfArray(source.json,'animations').entries()){
    const channels=new Map(),samplers=gltfArray(animation,'samplers');let duration=0;
    for(const channel of gltfArray(animation,'channels')){
      const node=gltfRef(channel.target?.node,skeleton.nodes,'animation node');if(!skeleton.active.has(node)){omitted++;continue;}
      const path=channel.target?.path;if(!['translation','rotation','scale'].includes(path))throw new Error(`Unsupported glTF animation target: ${String(path)}`);
      if(skeleton.nodes[node].matrix!==undefined)throw new Error('glTF animation cannot target a node with a matrix');
      const sampler=samplers[gltfRef(channel.sampler,samplers,'animation sampler')],times=readGltfAccessor(source,sampler.input),values=readGltfAccessor(source,sampler.output),interp=sampler.interpolation??'LINEAR',size=path==='rotation'?4:3;
      if(!['LINEAR','STEP','CUBICSPLINE'].includes(interp)||times.type!=='SCALAR'||times.componentType!==5126||times.normalized||values.componentType!==5126||values.normalized||values.size!==size||values.count!==times.count*(interp==='CUBICSPLINE'?3:1))throw new Error('Unsupported or invalid glTF animation sampler');
      if(times.data.some((t,i)=>t<0||(i>0&&t<=times.data[i-1])))throw new Error('glTF animation times must be nonnegative and strictly increasing');
      const metadata=source.json.accessors[sampler.input];if(!Array.isArray(metadata.min)||metadata.min.length!==1||!Array.isArray(metadata.max)||metadata.max.length!==1||!Number.isFinite(metadata.min[0])||!Number.isFinite(metadata.max[0])||Math.fround(metadata.min[0])!==times.data[0]||Math.fround(metadata.max[0])!==times.data.at(-1))throw new Error('glTF animation input min/max bounds must match actual times');
      if(path==='rotation')for(let i=0;i<times.count;i++){const at=(interp==='CUBICSPLINE'?i*3+1:i)*4;quaternion(values.data.subarray(at,at+4));}
      const record=channels.get(node)??{};if(record[path])throw new Error('Duplicate glTF animation channel');record[path]={times:times.data,values:values.data,size,interp};channels.set(node,record);duration=Math.max(duration,times.data.at(-1));
    }
    if(!channels.size)continue;
    const frameCount=duration>0?Math.ceil(duration*fps):1;
    if(!Number.isSafeInteger(frameCount)||frameCount<1||(frameCount+1)*9*4>0xffffffff)throw new Error('Baked glTF animation exceeds MDL frame representation');
    const tracks=skeleton.order.map(node=>{const pose=skeleton.poses[node],channel=channels.get(node)??{},data=new Float32Array((frameCount+1)*9);let previous;
      for(let f=0;f<=frameCount;f++){
        const time=f/fps,t=channel.translation?sampleAt(channel.translation,time,false):pose.t,q=quaternion(channel.rotation?sampleAt(channel.rotation,time,true):pose.r),s=channel.scale?sampleAt(channel.scale,time,false):pose.s,e=quatToEuler(q,previous);previous=e;
        const value=float32([t[0]*scale,t[1]*scale,t[2]*scale,...e,...s],'animation pose');if(value[6]===0||value[7]===0||value[8]===0)throw new Error('glTF animated zero scale cannot be represented as an editable pose');data.set(value,f*9);
      }return data;});
    const id=animations.length+1,name=gltfName(animation.name,`Animation ${ai+1}`);animations.push({id,name,mode,fps,frameCount,tracks});info.push({id,name,sourceDuration:duration,encodedDuration:frameCount/fps,fps,frameCount});
  }
  if(!animations.length){const tracks=skeleton.order.map(node=>{const pose=skeleton.poses[node],e=quatToEuler(pose.r),value=float32([pose.t[0]*scale,pose.t[1]*scale,pose.t[2]*scale,...e,...pose.s],'static pose');return Float32Array.from([...value,...value]);});animations.push({id:1,name:'Rest',mode,fps,frameCount:1,tracks});info.push({id:1,name:'Rest',sourceDuration:0,encodedDuration:1/fps,fps,frameCount:1,generated:true});}
  return {animations,info,omitted};
}
