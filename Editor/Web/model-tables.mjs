import { mdlsTail } from './vendor/mdl-codec.mjs';

const view=bytes=>new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
export function validateTables(doc,bones) {
  if(doc.version!==23 || doc.b8!==0 || doc.gap.length || doc.trailing.length!==1 || doc.trailing[0]!==0) throw new Error('Unsupported MDL structural layout');
  const versions={MDLS:'0004',MDAT:'0001',MDLA:'0006',MDLE:'0002'},seen=new Set();
  for(const section of doc.sections){
    if(seen.has(section.type) || section.raw || section.version!==versions[section.type] || section.b8!==0) throw new Error(`Unsupported ${section.type} section`);
    seen.add(section.type);
    if(section.type==='MDLS') validateSkeletonTail(section.tail,bones.length);
    if(section.type==='MDAT' && section.tail.length) throw new Error('Unsupported attachment tail');
    if(section.type==='MDLE' && (section.data.length!==bones.length*64 || section.tail.length)) throw new Error('Unsupported bind-pose table layout');
    if(section.type==='MDLA') for(const clip of section.anims){
      if(clip.tracks.length!==bones.length || !Number.isInteger(clip.frameCount) || clip.frameCount<1 ||
        clip.tracks.some(track=>track.data.length!==9*(clip.frameCount+1) || !track.data.every(Number.isFinite))) throw new Error('Unsupported animation track layout');
      if(clip.prefix.length!==31 || clip.prefix.some(v=>v!==0)) throw new Error('Unsupported animation trailer layout');
    }
  }
}
function validateSkeletonTail(tail,count) {
  if(!tail.length)return;
  const permutation=12+count*76+1,draw=permutation+count*4+1;
  if(tail.length!==14+84*count || tail.slice(0,11).some(v=>v!==0) || tail[11]!==1 || tail[permutation-1]!==1 || tail[draw-1]!==1) throw new Error('Unsupported skeleton tail layout');
  const dv=view(tail),values=Array.from({length:count},(_,i)=>dv.getUint32(permutation+i*4,true));
  if(new Set(values).size!==count || values.some(v=>v>=count)) throw new Error('Invalid skeleton tail permutation');
}
export function remapSkeletonTail(tail,previous,bones,sources,map) {
  if(!tail.length)return tail;
  const count=bones.length,oldCount=previous.length,result=new Uint8Array(14+84*count),input=view(tail),out=view(result);
  result.set(tail.subarray(0,12));
  const oldPermutation=12+oldCount*76+1,oldDraw=oldPermutation+oldCount*4+1;
  const permutation=12+count*76+1,draw=permutation+count*4+1;
  result[permutation-1]=1;result[draw-1]=1;
  sources.forEach((source,i)=>{
    if(source===null){
      result.set(mdlsTail([bones[i]]).subarray(12,88),12+i*76);
      out.setUint32(permutation+i*4,i,true);out.setInt32(draw+i*4,i*100,true);
    } else {
      result.set(tail.subarray(12+source*76,12+(source+1)*76),12+i*76);
      const next=map[input.getUint32(oldPermutation+source*4,true)];
      if(next<0)throw new Error('Deletion would invalidate the skeleton permutation');
      out.setUint32(permutation+i*4,next,true);out.setInt32(draw+i*4,input.getInt32(oldDraw+source*4,true),true);
    }
  });
  validateSkeletonTail(result,count);return result;
}
export function remapBindPose(data,bones,sources) {
  const result=new Uint8Array(bones.length*64),dv=view(result);
  sources.forEach((source,i)=>{
    if(source!==null)result.set(data.subarray(source*64,(source+1)*64),i*64);
    else bones[i].matrix.forEach((v,k)=>dv.setFloat32(i*64+k*4,v,true));
  });return result;
}
