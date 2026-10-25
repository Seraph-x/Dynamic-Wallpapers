import { modelFixture } from './model-fixtures.mjs';

export const migrationAnchors=['object','text','effect','material','general'];
// Function's global is deliberately observable in a real scene page. The
// sandbox supplies its own globalThis; recording there would hide execution.
export function migrationScript(anchor,{color=false}={}) {
 return `const host=({}).constructor.constructor('return globalThis')();
const probe=host.__migrationProbe??={};
const entry=probe[${JSON.stringify(anchor)}]??={top:0,init:0,update:0};entry.top++;host.fetch('/__project/materials/editor/rig.tex?migration-source-probe='+${JSON.stringify(anchor)}).then(response=>{entry.network=response.status;});
export function init(value){entry.init++;return value;}
export function update(value){entry.update++;${anchor==='material'?'entry.layerAlpha=thisLayer.alpha;':''}${color?"return Math.floor(engine.runtime*2)%2===0?{x:0,y:1,z:0}:{x:1,y:0,z:0};":"return value;"}}`;
}
const curve={options:{fps:2,length:2,mode:'mirror'},c0:[{frame:0,value:320},{frame:2,value:360}],c1:[{frame:0,value:180}],c2:[{frame:0,value:0}]};
export const migrationDocument={title:'Script migration',entry:'scene.json',project:{type:'scene',file:'scene.json',future:{preserved:true}},scene:{
 general:{orthogonalprojection:{width:640,height:360},clearcolor:'0.05 0.05 0.08',clearenabled:true,cameraparallax:false,zoom:{value:1,script:migrationScript('general')}},
 objects:[{id:1,name:'Migration rig',image:'models/editor/rig.json',origin:{value:'320 180 0',animation:curve},size:'100 30',scale:'1 1 1',angles:'0 0 0',color:{value:'0 1 0',script:migrationScript('object',{color:true}),future:{keep:true}},alpha:1,animationlayers:[{animation:7,blend:1,rate:1,visible:true}]},
 {id:3,name:'Migration material image',image:'models/editor/material.json',origin:'500 80 0',size:'40 40',scale:'1 1 1',color:'0 1 0',alpha:1,effects:[{file:'effects/editor/migration.json',visible:{value:true,script:migrationScript('effect')},passes:[]}]},
 {id:2,name:'Migration text',text:{value:'Migration',script:migrationScript('text')},font:'Arial',pointsize:16,origin:'100 70 0',color:'0 0 1',scale:'1 1 1',angles:'0 0 0',alpha:1,
 future:{script:'({}).constructor.constructor("return globalThis")().__migrationUnknownMetadataRan=true;'}}]}};
export function migrationResources(){return new Map([
 ['models/editor/rig.mdl',Buffer.from(modelFixture())],
 ['materials/editor/migration.json',Buffer.from(JSON.stringify({passes:[{shader:'editor/migration',textures:[],blending:'normal',constantshadervalues:{alpha:{value:1,script:migrationScript('material')}}}]}))],
 ['shaders/editor/migration.vert',Buffer.from('attribute vec3 a_Position;attribute vec2 a_TexCoord;varying vec2 v_TexCoord;uniform mat4 g_ModelViewProjectionMatrix;void main(){v_TexCoord=a_TexCoord;gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0);}')],
 ['shaders/editor/migration.frag',Buffer.from('uniform sampler2D g_Texture0;\n uniform float g_Alpha; // {"material":"alpha","default":1}\n varying vec2 v_TexCoord;void main(){gl_FragColor=texture(g_Texture0,v_TexCoord)*g_Alpha;}')],
 ['effects/editor/migration.json',Buffer.from(JSON.stringify({passes:[{material:'materials/editor/migration.json'}]}))],
 ['models/editor/material.json',Buffer.from(JSON.stringify({autosize:false,width:40,height:40,material:'materials/editor/rig.json'}))],
 ['models/editor/rig.json',Buffer.from(JSON.stringify({autosize:false,width:100,height:30,material:'materials/editor/rig.json',puppet:'models/editor/rig.mdl'}))],
 ['materials/editor/rig.json',Buffer.from(JSON.stringify({passes:[{defaultlight:false,shader:'genericimage4',textures:['editor/rig'],blending:'translucent',depthtest:'disabled',depthwrite:'disabled',cullmode:'nocull'}]}))],
 // Actual 4×4 white TEXV0005 from the pinned package encoder; using its
 // native texture form makes byte preservation testable through both exports.
 ['materials/editor/rig.tex',Buffer.from('VEVYVjAwMDUAVEVYSTAwMDEAAAAAAAIAAAAEAAAABAAAAAQAAAAEAAAAAAAAAFRFWEIwMDA0AAEAAAANAAAAAAAAAAEAAAAEAAAABAAAAAAAAACIAAAAiAAAAIlQTkcNChoKAAAADUlIRFIAAAAEAAAABAgGAAAAqfGefgAAAE9JREFUeAEBRAC7/wD/////////////////////AP////////////////////8A/////////////////////wD/////////////////////eDw/wdnH/TwAAAAASUVORK5CYII=','base64')],
]);}

// Real engine on a separate origin with an owned byte source, without any
// workbench module or Editor bridge. Used only by browser acceptance.
export async function openScriptPlayback(authoringPage,document,resources) {
 const {readFile}=await import('node:fs/promises');
 const engine=await readFile(new URL('../Sources/EditorApp/Resources/ScenePreviewWeb/webwallgl.bundle.mjs',import.meta.url));
 const page=await authoringPage.context().browser().newPage({viewport:{width:640,height:360}});
 await page.route('http://migration-preview.test/**',async route=>{
  if(new URL(route.request().url()).pathname==='/engine.mjs')await route.fulfill({contentType:'text/javascript',body:engine});
  else await route.fulfill({contentType:'text/html',body:'<!doctype html><style>html,body{margin:0}#scene{width:640px;height:360px}</style><div id="scene"></div>'});
 });
 await page.goto('http://migration-preview.test/');
 await page.evaluate(async({document,files})=>{
  const {createScene}=await import('/engine.mjs');
  const encode=value=>new TextEncoder().encode(JSON.stringify(value));
  const resources=new Map(files.map(([name,data])=>[name,Uint8Array.from(atob(data),c=>c.charCodeAt(0))]));
  const source={async project(){return document.project;},async sceneDir(){return {entry:document.entry,async read(name){if(name===document.entry)return encode(document.scene);if(name==='project.json')return encode(document.project);return resources.get(name)??null;}};}};
  globalThis.__playbackErrors=[];
  const instance=createScene(globalThis.document.getElementById('scene'),{fps:30,volume:0,fit:'contain',audio:{snapshot:()=>({left:new Float32Array(64),right:new Float32Array(64)})},media:null,autoQuality:false,debugHooks:false,onError:error=>globalThis.__playbackErrors.push(String(error))});
  globalThis.__migrationPlayback=instance;
  await instance.load(source);
 },{document,files:[...resources].map(([name,bytes])=>[name,Buffer.from(bytes).toString('base64')])});
 return page;
}
