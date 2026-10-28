import { createMdlDoc, writeMdlDoc } from './vendor/mdl-codec.mjs';
import { modelSpec } from './model-fixtures.mjs';
import { migrationResources } from './script-migration-fixture.mjs';

const encode=value=>Buffer.from(typeof value==='string'?value:JSON.stringify(value));
export const runtimeResourceSinks=['effect','mesh','per-mesh','tint','particle-uniform','particle-material','child-override','emitter-rate'];
export function runtimeResourceScript(name,body) {
 return `const host=({}).constructor.constructor('return globalThis')();
const probe=(host.__resourceProbe??={})[${JSON.stringify(name)}]??={top:0,init:0,update:0};probe.top++;
export function init(value){probe.init++;return value;}
export function update(value){probe.update++;${body}}
export function destroy(){probe.destroy=(probe.destroy??0)+1;}`;
}

export function resourceRuntimeFixture(sink,{source,disabled=false}={}) {
 if(!runtimeResourceSinks.includes(sink))throw new Error('Unknown real renderer resource fixture');
 const files=new Map(),put=(path,value)=>files.set(path,encode(value));
 const script=source??runtimeResourceScript(sink,'return {x:0,y:1,z:0,w:1};');
 const layer={id:1,name:sink,origin:'160 90 0',size:'100 70',scale:'1 1 1',angles:'0 0 0',color:'1 1 1',alpha:1};
 const scene={general:{orthogonalprojection:{width:320,height:180},clearenabled:true,clearcolor:'0 0 0',cameraparallax:false},objects:[layer]};
 files.set('materials/owned/white.tex',migrationResources().get('materials/editor/rig.tex'));
 put('shaders/owned/constant.vert','attribute vec3 a_Position;attribute vec2 a_TexCoord;uniform mat4 g_ModelViewProjectionMatrix;void main(){gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0);}');
 put('shaders/owned/constant.frag','uniform vec4 g_Value; // {"material":"Value","default":"1 0 0 1"}\n void main(){gl_FragColor=g_Value;}');
 put('shaders/owned/effect.vert','attribute vec3 a_Position;void main(){gl_Position=vec4(a_Position,1.0);}');
 put('shaders/owned/effect.frag','uniform vec4 g_Value; // {"material":"Value","default":"1 0 0 1"}\n void main(){gl_FragColor=g_Value;}');
 const baseMaterial={passes:[{shader:'generic4',textures:['owned/white'],blending:'normal',constantshadervalues:{}}]};
 put('models/owned/image.json',{width:100,height:70,material:'materials/owned/base.json'});
 put('materials/owned/base.json',baseMaterial);
 const custom=(code,shader='owned/constant')=>({passes:[{shader,defaultlight:false,cullmode:'nocull',textures:['owned/white'],blending:'normal',constantshadervalues:{Value:{value:'1 0 0 1',script:code}}}]});
 if(sink==='effect'){
  layer.image='models/owned/image.json';layer.effects=[{file:'effects/owned/constant.json',passes:[]}];
  put('effects/owned/constant.json',{passes:[{material:'materials/owned/effect.json'}]});
  put('materials/owned/effect.json',custom(script,'owned/effect'));
 }else if(sink==='tint'){
  layer.image='models/owned/image.json';
  baseMaterial.passes[0].constantshadervalues={Color:{value:'1 0 0',script:source??runtimeResourceScript(sink,'return {x:0,y:1,z:0};')}};
  put('materials/owned/base.json',baseMaterial);
 }else if(sink==='mesh'||sink==='per-mesh'){
  const spec=modelSpec();spec.animations=[];
  spec.meshes[0].material='materials/owned/mesh0.json';spec.meshes[1].material=sink==='mesh'?'materials/owned/mesh0.json':'materials/owned/mesh1.json';
  const doc=createMdlDoc(spec);files.set('models/owned/mesh.mdl',Buffer.from(writeMdlDoc(doc)));
  layer.model='models/owned/mesh.mdl';
  put('materials/owned/mesh0.json',custom(script));
  put('materials/owned/mesh1.json',custom(runtimeResourceScript(sink+'-second','return {x:0,y:0,z:1,w:1};')));
 }else{
  layer.particle='particles/owned/root.json';
  const particle={maxcount:200,material:'materials/owned/particle.json',emitter:[{name:'boxrandom',rate:0,instantaneous:1,distancemin:'0 0 0',distancemax:'0 0 0'}],initializer:[{name:'lifetimerandom',min:3,max:3},{name:'sizerandom',min:50,max:50},{name:'colorrandom',min:'255 255 255',max:'255 255 255'},{name:'alpharandom',min:1,max:1}],renderer:[{name:'spriterenderer'}]};
  const material={passes:[{shader:'genericparticle',textures:['owned/white'],blending:'translucent',constantshadervalues:{}}]};
  if(sink==='particle-uniform'){
   put('shaders/owned/particle.vert','attribute vec3 a_Position;attribute vec4 a_TexCoordVec4;uniform mat4 g_ModelViewProjectionMatrix;void main(){vec3 p=a_Position;p.xy+=(a_TexCoordVec4.xy-0.5)*a_TexCoordVec4.w*2.0;gl_Position=vec4(p,1.0)*g_ModelViewProjectionMatrix;}');
   put('shaders/owned/particle.frag','uniform vec4 g_Value; // {"material":"Value","default":"1 0 0 1"}\n void main(){gl_FragColor=g_Value;}');
   material.passes[0].shader='owned/particle';material.passes[0].constantshadervalues={Value:{value:'1 0 0 1',script}};
  }else if(sink==='particle-material')material.passes[0].constantshadervalues={ui_editor_properties_overbright:{value:1,script:source??runtimeResourceScript(sink,'return 0.2;')}};
  else if(sink==='child-override'){
   const child=structuredClone(particle);put('particles/owned/child.json',child);
   particle.emitter=[{rate:0}];particle.children=[{name:'particles/owned/child.json',origin:'0 0 0',instanceoverride:{alpha:{value:1,script:source??runtimeResourceScript(sink,'return 0.2;')}}}];
  }else if(sink==='emitter-rate')particle.emitter[0].rate={value:0,script:source??runtimeResourceScript(sink,'return 100;')};
  put('particles/owned/root.json',particle);put('materials/owned/particle.json',material);
 }
 put('scene.json',scene);put('project.json',{type:'scene',file:'scene.json'});
 return {sink,scene,files,options:{scripts:!disabled},samples:sink==='mesh'||sink==='per-mesh'?[[125,90],[195,90]]:[[160,90]]};
}
