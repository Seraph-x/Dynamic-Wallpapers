import { modelSpec } from './model-fixtures.mjs';
import { createMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';
export const eventPaths=['models/editor/rig.mdl','models/editor/rig.json','materials/editor/rig.json','materials/editor/rig.png'];
export const eventColorScript=`export function update(value){return value;}
export function animationEvent(event,value){
 if(event.name==='fire'||event.name==='Native fire')return {x:1,y:0,z:0};
 if(event.name==='reset')return {x:0,y:1,z:0};
 return value;
}`;
export const eventDocument={title:'Frame events',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{general:{orthogonalprojection:{width:640,height:360},clearcolor:'0.05 0.05 0.08',clearenabled:true,cameraparallax:false},objects:[{id:1,name:'Rig',image:eventPaths[1],origin:'320 180 0',size:'100 30',scale:'1 1 1',angles:'0 0 0',color:{value:'0 1 0',script:eventColorScript,future:{keep:true}},alpha:1,animationlayers:[{animation:7,blend:1,rate:1,visible:true}]}]}};
export function eventFixture(){
 const spec=modelSpec();spec.animations=[{id:7,name:'Event cycle',mode:'loop',fps:4,frameCount:8,tracks:spec.bones.map((bone,index)=>Float32Array.from({length:81},(_,i)=>{const k=i%9;return k===0?(index===1?-35:index===2?35:0):k>=6?1:0;})),events:[{frame:0,name:'reset'},{frame:2,name:'middle'},{frame:6,name:'reset'}]}];
 const doc=createMdlDoc(spec);doc.sections.find(s=>s.type==='MDLA').anims[0].events[1].json='{"frame":2, "name":"middle", "future":{"kept":true},"big":9007199254740993}';return writeMdlDoc(doc);
}
