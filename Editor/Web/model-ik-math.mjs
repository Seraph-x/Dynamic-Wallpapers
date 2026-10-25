// Rotation math uses Float64; hierarchy evaluation uses the native Float32 path.
export const add=(a,b)=>a.map((v,i)=>v+b[i]);
export const sub=(a,b)=>a.map((v,i)=>v-b[i]);
export const scale=(a,s)=>a.map(v=>v*s);
export const dot=(a,b)=>a.reduce((s,v,i)=>s+v*b[i],0);
export const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
export const length=a=>Math.hypot(...a);
export const unit=a=>scale(a,1/length(a));
export const identity=[1,0,0,0,1,0,0,0,1];
export const transform=(m,v)=>[0,1,2].map(r=>m[r]*v[0]+m[3+r]*v[1]+m[6+r]*v[2]);
export const multiply=(a,b)=>b.flatMap((_,i)=>i%3===0?transform(a,b.slice(i,i+3)):[]);
export const transpose=m=>[m[0],m[3],m[6],m[1],m[4],m[7],m[2],m[5],m[8]];
export function rotation(pose){
 const [x,y,z]=pose.slice(3,6),[cx,cy,cz]=[Math.cos(x),Math.cos(y),Math.cos(z)],[sx,sy,sz]=[Math.sin(x),Math.sin(y),Math.sin(z)];
 return [cz*cy,sz*cy,-sy,cz*sy*sx-sz*cx,sz*sy*sx+cz*cx,cy*sx,cz*sy*cx+sz*sx,sz*sy*cx-cz*sx,cy*cx];
}
/** Shortest arc; the pole plane selects the otherwise ambiguous half turn. */
export function align(from,to,planeNormal){
 const a=unit(from),b=unit(to),axis=cross(a,b),s=length(axis),c=dot(a,b);
 if(s<=64*Number.EPSILON){if(c>=0)return identity;return axisRotation(unit(planeNormal),-1,0);}
 return axisRotation(scale(axis,1/s),Math.max(-1,Math.min(1,c)),s);
}
function axisRotation([x,y,z],c,s){
 const t=1-c;
 return [t*x*x+c,t*x*y+s*z,t*x*z-s*y,t*x*y-s*z,t*y*y+c,t*y*z+s*x,t*x*z+s*y,t*y*z-s*x,t*z*z+c];
}
const nearAngle=(a,ref)=>a+2*Math.PI*Math.round((ref-a)/(2*Math.PI));
/** Equivalent Rz*Ry*Rx branches nearest the previous encoded sample. At the
 * gimbal singularity preserve its free Z angle rather than introducing a turn. */
export function eulerNear(m,reference){
 const y=Math.atan2(-m[2],Math.hypot(m[0],m[1]));
 let candidates;
 if(Math.hypot(m[0],m[1])<1e-10){
  const z=reference[2],x=Math.atan2(-m[7],m[4])+Math.sign(y)*z;
  candidates=[[x,y,z]];
 }else{
  const x=Math.atan2(m[5],m[8]),z=Math.atan2(m[1],m[0]);
  candidates=[[x,y,z],[x+Math.PI,Math.PI-y,z+Math.PI]];
 }
 return candidates.map(c=>c.map((v,i)=>nearAngle(v,reference[i])))
  .sort((a,b)=>dot(sub(a,reference),sub(a,reference))-dot(sub(b,reference),sub(b,reference)))[0];
}
export function elbow(positions,target,pole){
 const [a,b,c]=positions,first=length(sub(b,a)),second=length(sub(c,b)),distance=length(sub(target,a));
 if(!(first>0&&second>0))throw new Error('IK chain has a zero-length segment');
 if(!distance)throw new Error('IK target is coincident with chain root');
 const direction=unit(sub(target,a)),poleOffset=sub(pole,a),projection=sub(poleOffset,scale(direction,dot(poleOffset,direction)));
 if(length(projection)<=64*Number.EPSILON*length(poleOffset))throw new Error('IK pole is collinear with root and target');
 // Only Float64 round-off in analytic reach arithmetic is tolerated. The native
 // endpoint check remains mandatory after Euler/delta Float32 quantization.
 const reachRoundoff=64*Number.EPSILON*(first+second);
 if(distance>first+second+reachRoundoff||distance<Math.abs(first-second)-reachRoundoff)throw new Error('IK target is unreachable without stretching');
 const x=(first*first-second*second+distance*distance)/(2*distance),heightSquared=first*first-x*x;
 if(heightSquared< -64*Number.EPSILON*(first+second)**2)throw new Error('IK target is unreachable without stretching');
 const bend=unit(projection),point=add(a,add(scale(direction,x),scale(bend,Math.sqrt(Math.max(0,heightSquared)))));
 return {point,normal:cross(direction,bend),total:first+second};
}
