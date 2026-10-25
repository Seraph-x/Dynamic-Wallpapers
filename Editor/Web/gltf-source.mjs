import { safePath } from './document.mjs';
const decoder=new TextDecoder('utf-8',{fatal:true});
export const gltfInteger=(value,label,minimum=0)=>{if(!Number.isSafeInteger(value)||value<minimum)throw new Error(`Invalid glTF ${label}`);return value;};
export function gltfArray(json,key) {const value=json[key];if(value===undefined)return [];if(!Array.isArray(value))throw new Error(`Invalid glTF ${key} array`);return value;}
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
function archivePaths(files) {
  const names=new Map(),parents=new Map(),key=value=>value.normalize('NFC').toLowerCase();
  for(const file of files){
    safePath(file.path);if(/[\x00-\x1f\x7f]/.test(file.path))throw new Error('Invalid glTF source path controls');const normalized=key(file.path),parts=file.path.split('/');
    if(names.has(normalized))throw new Error(`Ambiguous glTF source path: ${file.path}`);names.set(normalized,file.path);
    for(let end=1;end<parts.length;end++){
      const path=parts.slice(0,end).join('/'),normalized=key(path),previous=parents.get(normalized);
      if(previous!==undefined&&previous!==path)throw new Error(`Ambiguous glTF source directory: ${path}`);parents.set(normalized,path);
    }
  }
  if([...names.keys()].some(path=>parents.has(path)))throw new Error('glTF source file/directory collision');
}
function dataBytes(uri) {
  const comma=uri.indexOf(',');if(comma<0)throw new Error('Invalid glTF data URI');const header=uri.slice(5,comma),body=uri.slice(comma+1);
  if(/;base64$/i.test(header)){
    if(!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(body))throw new Error('Invalid glTF data URI base64');
    const decoded=atob(body);if(btoa(decoded)!==body)throw new Error('Noncanonical glTF data URI base64');return Uint8Array.from(decoded,c=>c.charCodeAt(0));
  }
  const bytes=[];
  for(let i=0;i<body.length;i++){
    if(body[i]==='%'){const hex=body.slice(i+1,i+3);if(!/^[a-f0-9]{2}$/i.test(hex))throw new Error('Invalid glTF data URI escape');bytes.push(parseInt(hex,16));i+=2;}
    else{const code=body.charCodeAt(i);if(code>127)throw new Error('Non-ASCII glTF data URI byte must be escaped');bytes.push(code);}
  }
  return Uint8Array.from(bytes);
}
export function gltfLocalURI(uri,entry) {
  if(typeof uri!=='string'||!uri||/[?#\\\x00-\x1f\x7f]/.test(uri)||/^[a-z][a-z0-9+.-]*:/i.test(uri)||uri.startsWith('/')||/%(?:2f|5c)/i.test(uri))throw new Error(`Unsupported glTF local URI: ${String(uri)}`);
  let path;try{path=decodeURIComponent(uri);}catch{throw new Error('Invalid glTF URI escape');}
  if(/[\x00-\x1f\x7f]/.test(path))throw new Error('Invalid glTF URI path controls');safePath(path);return safePath(entry.slice(0,entry.lastIndexOf('/')+1)+path);
}
function container(bytes) {
  const unknownChunks=[];let bin;
  if(bytes.length<4||new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength).getUint32(0,true)!==0x46546c67)return {json:JSON.parse(decoder.decode(bytes)),unknownChunks};
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  if(bytes.length<12||view.getUint32(4,true)!==2||view.getUint32(8,true)!==bytes.length)throw new Error('Invalid GLB version or exact container length');
  let at=12,json,chunk=0;
  while(at<bytes.length){
    if(at+8>bytes.length)throw new Error('Incomplete GLB chunk header');const length=view.getUint32(at,true),type=view.getUint32(at+4,true);
    if(length%4||at+8+length>bytes.length)throw new Error('Invalid GLB chunk alignment or bounds');const data=bytes.subarray(at+8,at+8+length);
    if(chunk===0&&type!==0x4e4f534a)throw new Error('GLB JSON chunk must be first');
    if(type===0x4e4f534a){if(json!==undefined)throw new Error('Duplicate GLB JSON chunk');json=JSON.parse(decoder.decode(data));}
    else if(type===0x004e4942){if(bin!==undefined||chunk!==1)throw new Error('Duplicate or out-of-order GLB BIN chunk');bin=data;}
    else unknownChunks.push({type,byteLength:length});
    at+=8+length;chunk++;
  }
  if(json===undefined)throw new Error('Missing GLB JSON chunk');return {json,bin,unknownChunks};
}
export function parseGltfSource(source) {
  if(!object(source)||typeof source.entry!=='string'||!Array.isArray(source.files)||!source.files.length)throw new Error('Invalid glTF source bundle');safePath(source.entry);
  const files=source.files.map(file=>{
    if(!object(file)||typeof file.path!=='string'||!(file.bytes instanceof Uint8Array))throw new Error('Invalid glTF source file');return {path:file.path,bytes:file.bytes.slice()};
  });archivePaths(files);
  const inventory=new Map(files.map(file=>[file.path,file.bytes])),entry=inventory.get(source.entry);if(!entry)throw new Error('Missing glTF entry file');
  const extension=source.entry.split('.').at(-1).toLowerCase(),binary=entry.length>=4&&new DataView(entry.buffer,entry.byteOffset,entry.byteLength).getUint32(0,true)===0x46546c67;
  if(!['gltf','glb'].includes(extension)||(extension==='glb')!==binary)throw new Error('Selected glTF/GLB entry does not match its container');
  const {json,bin,unknownChunks}=container(entry);
  if(!object(json)||!object(json.asset)||json.asset.version!=='2.0'||(json.asset.minVersion!==undefined&&json.asset.minVersion!=='2.0'))throw new Error('Unsupported glTF asset version (expected 2.0)');
  const references=new Set([source.entry]);
  function readURI(uri){
    if(typeof uri!=='string')throw new Error('Invalid glTF resource URI');if(/^data:/i.test(uri))return dataBytes(uri);
    const path=gltfLocalURI(uri,source.entry),bytes=inventory.get(path);if(!bytes)throw new Error(`Missing glTF source file: ${path}`);references.add(path);return bytes.slice();
  }
  const buffers=gltfArray(json,'buffers').map((buffer,i)=>{
    if(!object(buffer))throw new Error('Invalid glTF buffer');const length=gltfInteger(buffer.byteLength,'buffer length',1);
    let bytes;if(buffer.uri===undefined){if(i!==0||bin===undefined)throw new Error('Missing GLB BIN buffer');bytes=bin;
      if(bytes.length-length<0||bytes.length-length>3||bytes.subarray(length).some(value=>value!==0))throw new Error('Invalid GLB buffer length/padding');
    }else bytes=readURI(buffer.uri);
    if(length>bytes.length)throw new Error('glTF buffer length exceeds supplied bytes');return bytes.subarray(0,length).slice();
  });
  const views=gltfArray(json,'bufferViews').map(view=>{
    if(!object(view))throw new Error('Invalid glTF bufferView');const buffer=buffers[gltfInteger(view.buffer,'bufferView buffer')],offset=gltfInteger(view.byteOffset??0,'bufferView offset'),length=gltfInteger(view.byteLength,'bufferView length',1);
    if(!buffer||!Number.isSafeInteger(offset+length)||offset+length>buffer.length)throw new Error('glTF bufferView bounds exceed buffer');
    const stride=view.byteStride===undefined?undefined:gltfInteger(view.byteStride,'bufferView stride',4);
    if(stride!==undefined&&(stride>252||stride%4))throw new Error('Invalid glTF bufferView stride');return {bytes:buffer.subarray(offset,offset+length),byteStride:stride,offset,target:view.target};
  });
  return {json,buffers,files,entry:source.entry,unknownChunks,references,readURI,view(index){const result=views[gltfInteger(index,'bufferView index')];if(!result)throw new Error('Missing glTF bufferView');return result;}};
}
