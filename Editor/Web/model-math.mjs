// The renderer composes local animation samples as Rz * Ry * Rx (radians).
export function restPose(matrix) {
  if (!matrix || matrix.length!==16 || !Array.from(matrix).every(Number.isFinite)) throw new Error('Expected a finite rest matrix');
  const m=Array.from(Float32Array.from(matrix));
  if(!m.every(Number.isFinite))throw new Error('Rest matrix must remain finite in Float32');
  const sx=Math.hypot(m[0],m[1],m[2]),sy=Math.hypot(m[4],m[5],m[6]),sz=Math.hypot(m[8],m[9],m[10]);
  const determinant=m[0]*(m[5]*m[10]-m[6]*m[9])-m[4]*(m[1]*m[10]-m[2]*m[9])+m[8]*(m[1]*m[6]-m[2]*m[5]);
  // parseSkeleton's reference layout uses this determinant tolerance. Checking
  // encoded Float32 values prevents authoring bones that playback will discard.
  if (!sx || !sy || !sz || !determinant || !Number.isFinite(determinant) ||
      Math.max(Math.abs(m[0]*m[5]-m[4]*m[1]),Math.abs(determinant))<=1e-9) throw new Error('Rest matrix must be invertible by the pinned renderer');
  if(m[3]!==0 || m[7]!==0 || m[11]!==0 || m[15]!==1)throw new Error('Native rest tracks cannot represent perspective');
  const signedX=determinant<0?-sx:sx,r20=m[2]/signedX,ry=Math.asin(Math.max(-1,Math.min(1,-r20)));
  const regular=Math.abs(Math.cos(ry))>1e-7;
  const rx=regular?Math.atan2(m[6]/sy,m[10]/sz):Math.atan2(-m[9]/sz,m[5]/sy);
  const rz=regular?Math.atan2(m[1]/signedX,m[0]/signedX):0;
  const pose=Float32Array.of(m[12],m[13],m[14],rx,ry,rz,signedX,sy,sz);
  const [cx,cy,cz]=[Math.cos(rx),Math.cos(ry),Math.cos(rz)],[ax,ay,az]=[Math.sin(rx),Math.sin(ry),Math.sin(rz)];
  const rebuilt=[cz*cy*signedX,az*cy*signedX,-ay*signedX,0,
    (cz*ay*ax-az*cx)*sy,(az*ay*ax+cz*cx)*sy,cy*ax*sy,0,
    (cz*ay*cx+az*ax)*sz,(az*ay*cx-cz*ax)*sz,cy*cx*sz,0,m[12],m[13],m[14],1];
  if (!Array.from(pose).every(Number.isFinite) || rebuilt.some((v,i)=>Math.abs(v-m[i])>1e-5*Math.max(1,Math.abs(m[i])))) {
    throw new Error('Rest matrix contains shear or perspective that a native TRS track cannot represent');
  }
  return pose.map(value=>value===0?0:value);
}
export function restMatrix(pose) {
  if(!Array.isArray(pose) || pose.length!==9 || !pose.every(Number.isFinite))throw new Error('Expected nine finite local TRS components');
  const [x,y,z,rx,ry,rz,sx,sy,sz]=pose;
  const [cx,cy,cz]=[Math.cos(rx),Math.cos(ry),Math.cos(rz)],[ax,ay,az]=[Math.sin(rx),Math.sin(ry),Math.sin(rz)];
  const result=Float32Array.of(cz*cy*sx,az*cy*sx,-ay*sx,0,
    (cz*ay*ax-az*cx)*sy,(az*ay*ax+cz*cx)*sy,cy*ax*sy,0,
    (cz*ay*cx+az*ax)*sz,(az*ay*cx-cz*ax)*sz,cy*cx*sz,0,x,y,z,1);
  restPose(result);return result;
}
