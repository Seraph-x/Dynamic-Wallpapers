import { safePath } from './document.mjs';
import { createImagePuppet } from './image-puppet.mjs';

const json=bytes=>JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
const directory=path=>path.slice(0,path.lastIndexOf('/')+1);
export function captureImageSource(editor,id) {
  const snapshot=editor.document.snapshot(),layer=snapshot.scene.objects?.find(layer=>layer.id===id);
  if(!layer||typeof layer.image!=='string'||layer.text!==undefined||layer.model!==undefined||editor.controls?.getModelInfo(id))throw new Error('Select an ordinary image layer');
  return Object.freeze({document:editor.document,id,path:safePath(layer.image),size:structuredClone(layer.size),overrides:Object.freeze({...snapshot.resourceOverrides})});
}
function assertCurrent(editor,source,materialPath) {
  const current=editor.document.snapshot(),layer=current.scene.objects?.find(layer=>layer.id===source.id);
  if(editor.document!==source.document||layer?.image!==source.path||layer?.text!==undefined||layer?.model!==undefined||JSON.stringify(layer?.size)!==JSON.stringify(source.size)||
      [source.path,materialPath].filter(Boolean).some(path=>current.resourceOverrides?.[path]!==source.overrides[path]))throw new Error('Image document or source resource changed; the conversion is stale');
}
function assertDestinations(editor,paths,original) {
  const key=path=>path.normalize('NFC').toLowerCase(),snapshot=editor.document.snapshot();
  const occupied=[snapshot.entry,'project.json',...original,...Object.keys(snapshot.resourceOverrides??{})];
  for(const path of paths){const candidate=key(path);
    if(occupied.some(existing=>key(existing)===candidate))throw new Error(`Mesh resource destination collision: ${path}`);
  }
  const files=new Map(),directories=new Map();
  for(const path of [...occupied,...paths]){
    const normalized=key(path),existing=files.get(normalized);
    if(existing!==undefined&&existing!==path)throw new Error(`Ambiguous resource path: ${path}`);
    files.set(normalized,path);const parts=path.split('/');
    for(let end=1;end<parts.length;end++){
      const parent=parts.slice(0,end).join('/'),normalizedParent=key(parent),existingParent=directories.get(normalizedParent);
      if(existingParent!==undefined&&existingParent!==parent)throw new Error(`Ambiguous resource directory: ${parent}`);
      directories.set(normalizedParent,parent);
    }
  }
  if([...files.keys()].some(path=>directories.has(path)))throw new Error('Mesh resource file/directory collision');
}
async function readJSON(editor,path) {
  const bytes=await editor.readResource(path);if(!bytes)throw new Error(`Missing image resource: ${path}`);
  return json(bytes);
}
export async function commitImagePuppet(editor,source,{columns,rows,rootName,identifier=crypto.randomUUID()}) {
  assertCurrent(editor,source);
  const model=await readJSON(editor,source.path);
  if(!model||typeof model!=='object'||Array.isArray(model))throw new Error('Image model JSON must be an object');
  const originalMaterial=safePath(model.material),material=await readJSON(editor,originalMaterial);assertCurrent(editor,source,originalMaterial);
  if(typeof identifier!=='string'||!/^[A-Za-z0-9_-]+$/.test(identifier))throw new Error('Invalid mesh resource identifier');
  const modelPath=directory(source.path)+identifier+'.puppet-model.json',mdlPath=directory(source.path)+identifier+'.puppet.mdl',materialPath=directory(originalMaterial)+identifier+'.puppet-material.json';
  const destinations=[modelPath,mdlPath,materialPath];let original=await editor.resourcePaths();assertDestinations(editor,destinations,original);
  for(const path of destinations)if(await editor.readResource(path)!==null)throw new Error(`Mesh resource destination already exists: ${path}`);
  const result=createImagePuppet({model,material,modelPath,mdlPath,materialPath,columns,rows,rootName,layerSize:source.size});
  const versions=[];
  for(const file of result.files){assertCurrent(editor,source,originalMaterial);versions.push(await editor.stageResource(file.data));}
  assertCurrent(editor,source,originalMaterial);
  // A destination may have been introduced while bytes were being staged.
  for(const path of destinations)if(await editor.readResource(path)!==null)throw new Error(`Mesh resource destination already exists: ${path}`);
  original=await editor.resourcePaths();assertCurrent(editor,source,originalMaterial);
  await editor.change(doc=>{
    assertCurrent(editor,source,originalMaterial);assertDestinations(editor,destinations,original);
    doc.transaction(draft=>{result.files.forEach((file,i)=>draft.resource(file.path,versions[i]));draft.retargetImage(source.id,source.path,modelPath);});
  });
  return result;
}
