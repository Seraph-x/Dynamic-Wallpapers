import {safePath} from './document.mjs';

const encoder=new TextEncoder(),decoder=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true});
const key=path=>path.normalize('NFC').toLowerCase();
const isArchive=path=>/^imports\/editor\/[^/]+\/(source\/|conversion\.json$)/.test(path);
const u32=value=>{if(!Number.isSafeInteger(value)||value<0||value>0xffffffff)throw new Error('Package field exceeds the unsigned 32-bit range');return value;};
function validatePaths(paths) {
  const files=new Set(),directories=new Map();
  for(const path of paths){
    safePath(path);if(decoder.decode(encoder.encode(path))!==path)throw new Error('Package path contains invalid Unicode');
    const normalized=key(path);if(files.has(normalized))throw new Error(`Duplicate or ambiguous package path: ${path}`);files.add(normalized);
    const parts=path.split('/');
    for(let end=1;end<parts.length;end++){
      const parent=parts.slice(0,end).join('/'),normalizedParent=key(parent),existing=directories.get(normalizedParent);
      if(existing!==undefined&&existing!==parent)throw new Error(`Ambiguous package directory: ${parent}`);directories.set(normalizedParent,parent);
    }
  }
  if([...files].some(path=>directories.has(path)))throw new Error('Package file/directory collision');
}
function parsePackage(bytes) {
  if(!(bytes instanceof Uint8Array))throw new Error('Package bytes must be a Uint8Array');
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);let cursor=0;
  const take=count=>{
    if(cursor>bytes.length||count>bytes.length-cursor)throw new Error('Package table is truncated or out of bounds');
    const start=cursor;cursor+=count;return bytes.subarray(start,cursor);
  };
  const number=()=>{const start=cursor;take(4);return view.getUint32(start,true);};
  if(number()!==8||!/^PKGV00(?:1[2-9]|2[0-3])$/.test(decoder.decode(take(8))))throw new Error('Unsupported package header or version');
  const count=number();if(count>Math.floor((bytes.length-cursor)/13))throw new Error('Package entry count exceeds its table bounds');
  const records=[];
  for(let index=0;index<count;index++)records.push({path:decoder.decode(take(number())),offset:number(),length:number()});
  validatePaths(records.map(record=>record.path));
  const entries=new Map(),ranges=[];
  for(const record of records){
    if(record.offset>bytes.length-cursor||record.length>bytes.length-cursor-record.offset)throw new Error(`Package resource is out of bounds: ${record.path}`);
    const start=cursor+record.offset,end=start+record.length;entries.set(record.path,{start,end});if(record.length)ranges.push({start,end});
  }
  ranges.sort((left,right)=>left.start-right.start);
  for(let index=1;index<ranges.length;index++)if(ranges[index].start<ranges[index-1].end)throw new Error('Package resource ranges overlap');
  return {paths:records.map(record=>record.path),entries};
}
// Mirrors the native checked reader. Neither the caller's container nor returned
// resource copies can mutate this reader's owned snapshot.
export function readEditorPackage(input) {
  if(!(input instanceof Uint8Array))throw new Error('Package bytes must be a Uint8Array');
  const bytes=new Uint8Array(input),{paths,entries}=parsePackage(bytes);
  return Object.freeze({paths:Object.freeze(paths),read(path){
    safePath(path);const entry=entries.get(path);if(!entry)throw new Error(`Missing package resource: ${path}`);
    return bytes.slice(entry.start,entry.end);
  }});
}
function writePackage(files) {
  u32(files.length);const entries=files.map(file=>({...file,name:encoder.encode(file.path)}));
  let tableLength=16,payloadLength=0;
  for(const file of entries){
    tableLength+=12+u32(file.name.length);u32(payloadLength);payloadLength+=u32(file.data.length);
    if(!Number.isSafeInteger(tableLength+payloadLength))throw new Error('Package total length exceeds the safe integer range');
  }
  const bytes=new Uint8Array(tableLength+payloadLength),view=new DataView(bytes.buffer);
  view.setUint32(0,8,true);bytes.set(encoder.encode('PKGV0023'),4);view.setUint32(12,entries.length,true);
  let cursor=16,offset=0;
  for(const file of entries){
    view.setUint32(cursor,file.name.length,true);cursor+=4;bytes.set(file.name,cursor);cursor+=file.name.length;
    view.setUint32(cursor,offset,true);view.setUint32(cursor+4,file.data.length,true);cursor+=8;
    bytes.set(file.data,tableLength+offset);offset+=file.data.length;
  }
  return bytes;
}
export function buildEditorPackage(input,buildScenePkg) {
  if(!Array.isArray(input)||typeof buildScenePkg!=='function')throw new Error('Package files and synchronous builder are required');
  const files=Array.from(input,file=>{
    if(!file||!(file.data instanceof Uint8Array))throw new Error('Package resource bytes must be a Uint8Array');
    return {path:file.path,data:new Uint8Array(file.data)};
  });
  validatePaths(files.map(file=>file.path));
  const archive=files.filter(file=>isArchive(file.path)),normal=files.filter(file=>!isArchive(file.path));
  const result=buildScenePkg(normal);if(!archive.length)return result;
  if(!result||result.then||!(result.pkg instanceof Uint8Array))throw new Error('Invalid synchronous package builder result');
  const {paths,entries}=parsePackage(result.pkg);
  validatePaths([...paths,...archive.map(file=>file.path)]);
  const merged=[...paths.map(path=>{const {start,end}=entries.get(path);return {path,data:result.pkg.subarray(start,end)};}),...archive];
  return {...result,pkg:writePackage(merged),entries:merged.map(file=>file.path).sort()};
}
