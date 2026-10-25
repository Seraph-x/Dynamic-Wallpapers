import {SceneDocument,safePath} from './document.mjs';

const documents=new WeakMap(),previews=new WeakMap();
const key=path=>path.normalize('NFC').toLowerCase();
const encode=value=>JSON.stringify(value);
function freeze(value) {
  if(value&&typeof value==='object'){for(const item of Object.values(value))freeze(item);Object.freeze(value);}
  return value;
}
export function captureGltfDocument(editor) {
  const document=editor.document,snapshot=freeze(document.snapshot()),source=Object.freeze({document,snapshot});
  documents.set(source,{document,content:encode(snapshot)});return source;
}
function assertCurrent(editor,source) {
  const captured=documents.get(source);
  if(!captured||editor.document!==captured.document||encode(editor.document.snapshot())!==captured.content)throw new Error('glTF import document changed; the import is stale');
}
function assertPaths(paths,occupied=[]) {
  const destinations=new Set();
  for(const path of paths){safePath(path);const normalized=key(path);
    if(destinations.has(normalized)||occupied.some(existing=>key(existing)===normalized))throw new Error(`glTF resource destination collision: ${path}`);
    destinations.add(normalized);
  }
  const files=new Map(),directories=new Map();
  for(const path of [...occupied,...paths]){
    safePath(path);const normalized=key(path),existing=files.get(normalized);
    if(existing!==undefined&&existing!==path)throw new Error(`Ambiguous glTF resource path: ${path}`);
    files.set(normalized,path);const parts=path.split('/');
    for(let end=1;end<parts.length;end++){
      const parent=parts.slice(0,end).join('/'),normalizedParent=key(parent),existingParent=directories.get(normalizedParent);
      if(existingParent!==undefined&&existingParent!==parent)throw new Error(`Ambiguous glTF resource directory: ${parent}`);
      directories.set(normalizedParent,parent);
    }
  }
  if([...files.keys()].some(path=>directories.has(path)))throw new Error('glTF resource file/directory collision');
}
function copyCandidate(candidate) {
  if(!candidate||typeof candidate!=='object'||!Array.isArray(candidate.files)||!candidate.files.length||
      !Number.isSafeInteger(candidate.boneCount)||candidate.boneCount<0||typeof candidate.requiresUnlitConsent!=='boolean')throw new Error('Invalid glTF import candidate');
  const files=candidate.files.map(file=>{
    if(!file||!(file.data instanceof Uint8Array))throw new Error('Invalid glTF candidate resource bytes');
    return {path:safePath(file.path),data:file.data.slice()};
  });
  assertPaths(files.map(file=>file.path));safePath(candidate.mdlPath);
  if(!files.some(file=>file.path===candidate.mdlPath))throw new Error('glTF candidate is missing its model resource');
  return {files,mdlPath:candidate.mdlPath,bounds:structuredClone(candidate.bounds),boneCount:candidate.boneCount,
    requiresUnlitConsent:candidate.requiresUnlitConsent,requiresTwoSidedConsent:candidate.requiresTwoSidedConsent===true,identifier:structuredClone(candidate.identifier)};
}
function sameCandidate(candidate,captured) {
  if(!candidate||!Array.isArray(candidate.files))return false;
  const files=candidate.files,{files:original,...originalDetails}=captured;
  const details={mdlPath:candidate.mdlPath,bounds:candidate.bounds,boneCount:candidate.boneCount,
    requiresUnlitConsent:candidate.requiresUnlitConsent,requiresTwoSidedConsent:candidate.requiresTwoSidedConsent===true,identifier:candidate.identifier};
  return encode(details)===encode(originalDetails)&&files.length===original.length&&original.every((file,index)=>{
    const current=files[index];
    return current?.path===file.path&&current.data instanceof Uint8Array&&current.data.length===file.data.length&&current.data.every((byte,offset)=>byte===file.data[offset]);
  });
}
// Called by the real engine preview only after successful rendering and linked
// palette measurement. Keep a private byte snapshot: typed arrays cannot freeze.
export function captureGltfPreview(candidate,capacity) {
  const captured=copyCandidate(candidate);
  if(!Number.isSafeInteger(capacity)||capacity<1||captured.boneCount>capacity)throw new Error('glTF model exceeds the actual preview palette capacity');
  const preview=Object.freeze({candidate,capacity});previews.set(preview,captured);return preview;
}
function assertPreview(candidate,preview) {
  const captured=previews.get(preview);
  if(!captured||preview.candidate!==candidate||!sameCandidate(candidate,captured))throw new Error('glTF candidate changed or has no successful engine preview');
  return captured;
}
function assertDestinations(editor,paths,inventory) {
  if(!Array.isArray(inventory))throw new Error('Invalid project resource inventory');
  const snapshot=editor.document.snapshot();
  assertPaths(paths,[snapshot.entry,'project.json',...inventory,...Object.keys(snapshot.resourceOverrides??{})]);
}
async function checkAbsent(editor,source,candidate,preview,paths) {
  for(const path of paths){
    const bytes=await editor.readResource(path);assertCurrent(editor,source);assertPreview(candidate,preview);
    if(bytes!==null)throw new Error(`glTF resource destination already exists: ${path}`);
  }
}
export async function commitGltfImport(editor,source,candidate,{name,origin,allowUnlit=false,preview}={}) {
  assertCurrent(editor,source);const captured=assertPreview(candidate,preview);
  if(captured.requiresUnlitConsent&&allowUnlit!==true)throw new Error('Explicit consent is required for PBR-to-unlit conversion');
  if(captured.requiresTwoSidedConsent&&allowUnlit!==true)throw new Error('Explicit consent is required for single-sided to two-sided material conversion');
  const model={name,origin:structuredClone(origin),model:captured.mdlPath,bounds:captured.bounds};
  // Validate insertion before staging without changing the live document/history.
  new SceneDocument(editor.document.snapshot()).addModel(model);
  const paths=captured.files.map(file=>file.path);let inventory=await editor.resourcePaths();
  assertCurrent(editor,source);assertPreview(candidate,preview);assertDestinations(editor,paths,inventory);
  await checkAbsent(editor,source,candidate,preview,paths);
  const versions=[];
  for(const file of captured.files){
    const version=await editor.stageResource(file.data.slice());assertCurrent(editor,source);assertPreview(candidate,preview);
    if(typeof version!=='string'||!/^[a-f0-9]{64}$/.test(version))throw new Error('Invalid staged glTF resource version');
    versions.push(version);
  }
  await checkAbsent(editor,source,candidate,preview,paths);
  inventory=await editor.resourcePaths();assertCurrent(editor,source);assertPreview(candidate,preview);assertDestinations(editor,paths,inventory);
  let id;
  await editor.change(doc=>{
    assertCurrent(editor,source);assertPreview(candidate,preview);assertDestinations(editor,paths,inventory);
    if(doc!==source.document)throw new Error('glTF import document changed; the import is stale');
    doc.transaction(draft=>{captured.files.forEach((file,index)=>draft.resource(file.path,versions[index]));id=draft.addModel(model);});
  });
  return {id,mdlPath:captured.mdlPath,files:captured.files.map(file=>({path:file.path,data:file.data.slice()}))};
}
