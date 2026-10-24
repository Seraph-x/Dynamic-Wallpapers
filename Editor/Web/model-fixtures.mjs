import { createMdlDoc, writeMdlDoc } from './vendor/mdl-codec.mjs';

export const translation = (x=0,y=0,z=0) => Float32Array.of(1,0,0,0,0,1,0,0,0,0,1,0,x,y,z,1);
export function modelSpec() {
  const tracks = [0,1,2].map(bone => {
    const data = new Float32Array(3*9);
    for(let frame=0;frame<3;frame++) data.set([bone===1?-35:bone===2?35:0,bone===2?frame*30:0,0,0,0,0,1,1,1],frame*9);
    return data;
  });
  const mesh = (joint,x) => ({material:'materials/editor/rig.json',positions:Float32Array.of(x-15,-15,0,x+15,-15,0,x+15,15,0,x-15,15,0),
    uvs:Float32Array.of(0,1,1,1,1,0,0,0),indices:Uint32Array.of(0,1,2,0,2,3),
    boneIdx:Uint32Array.from({length:16},(_,i)=>i%4===0?joint:0),weights:Float32Array.from({length:16},(_,i)=>i%4===0?1:0)});
  return {meshes:[mesh(1,-35),mesh(2,35)],bones:[{name:'Root',parent:-1,matrix:translation(),head0:11,meta:'{"stiffness":0.7}'},
    {name:'Left',parent:0,matrix:translation(-35),head0:22,meta:'{"future":"left"}'},{name:'Right',parent:0,matrix:translation(35),head0:33,meta:'{"future":"right"}'}],
    animations:[{id:7,name:'Move right',mode:'mirror',fps:2,frameCount:2,tracks,events:[{frame:1,name:'middle'}]}],
    attachments:[{name:'Right tip',bone:2,matrix:translation(0,20)}]};
}
export function modelFixture() {
  const doc=createMdlDoc(modelSpec());
  doc.sections.find(s=>s.type==='MDLA').anims[0].events[0].json='{"frame":1,"name":"middle","future":{"kept":true}}';
  return writeMdlDoc(doc);
}
