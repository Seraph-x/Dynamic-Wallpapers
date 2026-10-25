import { safePath } from './document.mjs';
import { modelResourceSource } from './model-resource-edit.mjs';
import { assertMixTable } from './model-mixing.mjs';

const pins=new WeakMap();
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const pathKey=path=>path.normalize('NFC').toLowerCase();
const clipID=value=>Number.isInteger(value)&&value>=0&&value<=0xffffffff;
const equal=(left,right)=>{
  if(Object.is(left,right))return true;
  if(Array.isArray(left))return Array.isArray(right)&&left.length===right.length&&left.every((value,index)=>equal(value,right[index]));
  if(!object(left)||!object(right))return false;
  const keys=Object.keys(left);
  return keys.length===Object.keys(right).length&&keys.every(key=>Object.hasOwn(right,key)&&equal(left[key],right[key]));
};
function freeze(value) {
  if(value&&typeof value==='object'){Object.values(value).forEach(freeze);Object.freeze(value);}
  return value;
}
function stateOf(source) {
  const state=pins.get(source);
  if(!state)throw new Error('Invalid captured model clip source');
  return state;
}
function assertCurrent(editor,source) {
  const state=stateOf(source);
  if(editor.document!==source.document||editor.controls?.getModelInfo(source.id)?.mdlPath!==source.path||
      !equal(editor.document.snapshot(),state.snapshot))throw new Error('Model document, binding or resource changed; the clip edit is stale');
  return state;
}
export function captureClipSource(editor,id,expectedBytes) {
  if(!(expectedBytes instanceof Uint8Array))throw new Error('Expected loaded model bytes to capture clip ownership');
  const model=modelResourceSource(editor,id),snapshot=freeze(editor.document.snapshot());
  const layer=snapshot.scene.objects?.find(layer=>layer.id===id);
  if(!layer||layer.text!==undefined||typeof layer.image!=='string'&&typeof layer.model!=='string'||
      layer.image!==undefined&&layer.model!==undefined)throw new Error('Select an image or model layer');
  if(typeof layer.model==='string'&&safePath(layer.model)!==model.path)throw new Error('Loaded model path does not match its scene binding');
  const source=Object.freeze({...model,snapshot});
  pins.set(source,{snapshot,bytes:new Uint8Array(expectedBytes),resources:new Map()});
  return source;
}
async function assertModelCurrent(editor,source) {
  const state=assertCurrent(editor,source),value=await editor.readResource(source.path);
  assertCurrent(editor,source);
  if(!(value instanceof Uint8Array))throw new Error(`Missing model resource: ${source.path}`);
  const bytes=new Uint8Array(value);
  if(bytes.length!==state.bytes.length||bytes.some((value,index)=>value!==state.bytes[index]))throw new Error(`Model resource bytes changed; the clip edit is stale: ${source.path}`);
  return state;
}
function registerPath(paths,path) {
  safePath(path);
  const key=pathKey(path),existing=paths.get(key);
  if(existing!==undefined&&existing!==path)throw new Error(`Ambiguous model resource path: ${path}`);
  paths.set(key,path);return path;
}
async function readImage(editor,source,path) {
  const state=await assertModelCurrent(editor,source),value=await editor.readResource(path);assertCurrent(editor,source);
  if(!(value instanceof Uint8Array))throw new Error(`Missing image resource: ${path}`);
  const bytes=new Uint8Array(value);
  await assertModelCurrent(editor,source);
  const pinned=state.resources.get(path);
  if(pinned&&(pinned.length!==bytes.length||pinned.some((value,index)=>value!==bytes[index])))throw new Error(`Image model resource changed; the clip edit is stale: ${path}`);
  if(!pinned)state.resources.set(path,new Uint8Array(bytes));
  const model=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  if(!object(model))throw new Error(`Image model JSON must be an object: ${path}`);
  return model;
}
async function sharingLayers(editor,source) {
  await assertModelCurrent(editor,source);
  const paths=new Map(),images=new Map(),sharing=[];
  for(const path of [source.path,...Object.keys(source.snapshot.resourceOverrides??{})])registerPath(paths,path);
  for(const layer of source.snapshot.scene.objects??[]){
    if(layer.text!==undefined)continue;
    const info=editor.controls?.getModelInfo(layer.id);let path;
    if(layer.model!==undefined){
      if(layer.image!==undefined||typeof layer.model!=='string')throw new Error('Cannot verify a controlled or unsupported model resource path');
      path=registerPath(paths,layer.model);
    }else if(layer.image!==undefined){
      if(typeof layer.image!=='string')throw new Error('Cannot verify a controlled image model resource path');
      const image=registerPath(paths,layer.image);
      let model=images.get(image);
      if(!model){model=await readImage(editor,source,image);images.set(image,model);}
      if(model.puppet!==undefined){
        if(typeof model.puppet!=='string')throw new Error('Cannot verify a controlled image puppet model path');
        path=registerPath(paths,model.puppet);
      }
    }else if(info?.mdlPath)throw new Error('Loaded model has no verifiable scene resource binding');
    if(info?.mdlPath!==undefined&&info.mdlPath!==path)throw new Error('Loaded model path disagrees with image or scene resource metadata');
    if(path===source.path)sharing.push(layer);
  }
  await assertModelCurrent(editor,source);
  return sharing;
}
function references(layer,path) {
  const table=layer.animationlayers,base={id:layer.id,name:layer.name??String(layer.id),path};
  if(table===undefined||table===null||Array.isArray(table)&&table.length===0)return {...base,default:true,referenced:[]};
  if(!Array.isArray(table)||table.some(entry=>!object(entry)||!clipID(entry.animation)))throw new Error(`Cannot verify controlled or unsupported animation references on layer ${layer.id}`);
  return {...base,default:false,referenced:[...new Set(table.map(entry=>entry.animation))]};
}
export async function inspectClipReferences(editor,source) {
  const layers=(await sharingLayers(editor,source)).map(layer=>references(layer,source.path));
  await assertModelCurrent(editor,source);
  return {referenced:[...new Set(layers.flatMap(layer=>layer.referenced))],
    defaults:layers.filter(layer=>layer.default).map(({id,name})=>({id,name})),layers};
}
export async function commitClipResource(editor,source,bytes,{deletedID,animationLayers}={}) {
  assertCurrent(editor,source);
  const table=animationLayers===undefined?undefined:structuredClone(assertMixTable(animationLayers));
  if(!(bytes instanceof Uint8Array))throw new Error('Expected edited model bytes');
  if(deletedID!==undefined&&!clipID(deletedID))throw new Error('Invalid deleted model clip ID');
  // Own the candidate before any resource read yields to another editor action.
  const candidate=new Uint8Array(bytes);
  await assertModelCurrent(editor,source);
  if(deletedID!==undefined){
    const references=await inspectClipReferences(editor,source);
    if(references.referenced.includes(deletedID))throw new Error('Model clip is referenced by explicit scene playback; reassign its layers before deletion');
  }else await sharingLayers(editor,source);
  await assertModelCurrent(editor,source);
  const version=await editor.stageResource(candidate);await assertModelCurrent(editor,source);
  // JSON can be read from a host resource as well as an immutable override. Pin its actual bytes too.
  await sharingLayers(editor,source);await assertModelCurrent(editor,source);
  await editor.change(doc=>{assertCurrent(editor,source);
    if(table===undefined)doc.resource(source.path,version);
    else doc.transaction(value=>{value.resource(source.path,version);value.modelAnimationLayers(source.id,table);});
  });
}
export async function commitClipLayers(editor,source,layers) {
  assertCurrent(editor,source);const table=structuredClone(assertMixTable(layers));
  await sharingLayers(editor,source);await assertModelCurrent(editor,source);
  await editor.change(doc=>{assertCurrent(editor,source);doc.modelAnimationLayers(source.id,table);});
}
export async function commitClipPlayback(editor,source,id) {
  assertCurrent(editor,source);
  if(id!==null&&!clipID(id))throw new Error('Invalid model animation clip ID');
  await sharingLayers(editor,source);await assertModelCurrent(editor,source);
  await editor.change(doc=>{assertCurrent(editor,source);doc.modelAnimation(source.id,id);});
}
