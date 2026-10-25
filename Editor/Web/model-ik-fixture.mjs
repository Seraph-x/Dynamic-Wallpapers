import { createMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';
import { translation } from './model-fixtures.mjs';
export const ikPaths=['models/editor/ik.mdl','models/editor/ik.json','materials/editor/ik.json','materials/editor/ik.png'];
export const ikDocument={title:'IK posing',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{general:{orthogonalprojection:{width:640,height:360},clearcolor:'0.05 0.05 0.08',clearenabled:true,cameraparallax:false},objects:[{id:1,name:'IK rig',image:ikPaths[1],origin:'320 180 0',size:'86 16',scale:'1 1 1',angles:'0 0 0',color:'1 1 1',alpha:1,animationlayers:[{animation:7,blend:1,rate:1,visible:true}]}]}};
export function ikFixture(){
 const names=['root','middle','tip'],positions=[-35,0,35],tracks=positions.map((_,bone)=>{const data=new Float32Array(27);for(let f=0;f<3;f++)data.set([bone===0?-35:35,0,0,0,0,0,1,1,1],f*9);return data;});
 const meshes=positions.map((x,joint)=>({material:ikPaths[2],positions:Float32Array.of(x-8,-8,0,x+8,-8,0,x+8,8,0,x-8,8,0),uvs:Float32Array.of((joint+.25)/3,.75,(joint+.75)/3,.75,(joint+.75)/3,.25,(joint+.25)/3,.25),indices:Uint32Array.of(0,1,2,0,2,3),boneIdx:Uint32Array.from({length:16},(_,i)=>i%4===0?joint:0),weights:Float32Array.from({length:16},(_,i)=>i%4===0?1:0)}));
 const doc=createMdlDoc({meshes,bones:names.map((name,bone)=>({name,parent:bone-1,matrix:translation(bone===0?-35:35),head0:11+bone,meta:JSON.stringify({kept:name})})),animations:[{id:7,name:'IK pose',mode:'mirror',fps:2,frameCount:2,tracks,events:[{frame:1,name:'retained'}]}],attachments:[{name:'Tip',bone:2,matrix:translation(0,5)}]});
 return writeMdlDoc(doc);
}
