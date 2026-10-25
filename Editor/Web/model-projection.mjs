export function projectWeightMap(mesh,width,height) {
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity;
  for(let i=0;i<mesh.vertexCount;i++){const x=mesh.positions[i*3],y=mesh.positions[i*3+1];minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);}
  const scale=Math.min((width-24)/(maxX-minX||1),(height-24)/(maxY-minY||1));
  return Array.from({length:mesh.vertexCount},(_,i)=>[(mesh.positions[i*3]-(minX+maxX)/2)*scale+width/2,height/2-(mesh.positions[i*3+1]-(minY+maxY)/2)*scale]);
}
