const finite=Number.isFinite;
function point(value) {
  if(!Array.isArray(value)||value.length!==2||!value.every(finite))throw new Error('Expected a finite brush point');
  return value.slice();
}
function distance(p,a,b) {
  const dx=b[0]-a[0],dy=b[1]-a[1],px=p[0]-a[0],py=p[1]-a[1],length=Math.hypot(dx,dy);
  if(![dx,dy,px,py,length].every(finite))throw new Error('Brush segment exceeds numeric representation');
  if(!length)return Math.hypot(px,py);
  const ux=dx/length,uy=dy/length,t=Math.max(0,Math.min(length,px*ux+py*uy));
  return Math.hypot(px-t*ux,py-t*uy);
}
function influences(mesh,vertex,boneCount) {
  const entries=new Map();let largest=0;
  for(let k=0;k<4;k++){
    const joint=mesh.joints[vertex*4+k],weight=mesh.weights[vertex*4+k];
    if(!Number.isInteger(joint)||joint<0||joint>=boneCount||!finite(weight)||weight<0)throw new Error('Invalid mesh skin influence');
    largest=Math.max(largest,weight);
  }
  if(!largest)throw new Error('A mesh vertex has zero total weight');
  for(let k=0;k<4;k++){const joint=mesh.joints[vertex*4+k],weight=mesh.weights[vertex*4+k]/largest;if(weight)entries.set(joint,(entries.get(joint)??0)+weight);}
  const total=[...entries.values()].reduce((a,b)=>a+b,0);
  return [...entries].map(([joint,weight])=>({joint,weight:weight/total}));
}
function paint(base,bone,value) {
  const current=base.find(i=>i.joint===bone)?.weight??0;
  if(current===value)return undefined;
  const others=base.filter(i=>i.joint!==bone),remaining=others.reduce((sum,i)=>sum+i.weight,0);
  if(value<1&&!remaining)throw new Error('Reducing the sole skin influence requires another surviving weighted joint');
  const result=others.map(i=>({joint:i.joint,weight:(1-value)*(i.weight/remaining)})).filter(i=>i.weight>0);
  if(value>0)result.push({joint:bone,weight:value});
  if(result.length>4)throw new Error('Painting would require more than four positive skin influences');
  if(result.some(i=>!finite(i.weight)||Math.fround(i.weight)===0))throw new Error('Painted influence cannot be represented in native Float32 weights');
  return result;
}
export function createWeightStroke({mesh,points,bone,boneCount,radius,target,strength}) {
  if(!Number.isInteger(boneCount)||boneCount<1||!Number.isInteger(bone)||bone<0||bone>=boneCount)throw new Error('Invalid brush bone');
  if(!finite(radius)||radius<=0||![target,strength].every(v=>finite(v)&&v>=0&&v<=1))throw new Error('Invalid brush radius, target or strength');
  const count=mesh?.vertexCount;
  if(!Number.isInteger(count)||count<1||mesh.joints?.length!==count*4||mesh.weights?.length!==count*4||!Array.isArray(points)||points.length!==count)throw new Error('Invalid brush mesh or projection');
  const source=structuredClone(mesh),projection=points.map(point),base=Array.from({length:count},(_,i)=>influences(source,i,boneCount));
  const distances=new Float64Array(count).fill(Infinity);let previous;
  function edits() {
    const result=[];
    for(let i=0;i<count;i++){
      const coverage=Math.max(0,1-distances[i]/radius),amount=strength*coverage;if(!amount)continue;
      const current=base[i].find(i=>i.joint===bone)?.weight??0,value=current+amount*(target-current),next=paint(base[i],bone,value);
      if(next)result.push({vertex:i,influences:next});
    }
    return result;
  }
  return {move(value){const next=point(value),start=previous??next;
    const nextDistances=projection.map((p,i)=>Math.min(distances[i],distance(p,start,next)));
    distances.set(nextDistances);previous=next;
  },edits,preview(){
    const result=structuredClone(source);
    for(const edit of edits())for(let k=0;k<4;k++){result.joints[edit.vertex*4+k]=edit.influences[k]?.joint??0;result.weights[edit.vertex*4+k]=edit.influences[k]?.weight??0;}
    return result;
  }};
}
