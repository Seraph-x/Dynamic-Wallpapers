import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {encodePng} from './vendor/gltf-png.mjs';
import {buildEditorPackage,readEditorPackage} from './package-archive.mjs';

// Run the unchanged pinned pure writer in Node without importing its unrelated
// renderer re-export, which installs browser DOM event handlers at module load.
const source=await readFile(new URL('./.build/node_modules/@webwallgl/editor/webwallgl-editor.mjs',import.meta.url),'utf8');
const rendererExport='export * from "webwallgl";\n';assert(source.startsWith(rendererExport));
const {buildScenePkg}=await import('data:text/javascript;base64,'+Buffer.from(source.slice(rendererExport.length)).toString('base64'));
const encode=value=>new TextEncoder().encode(value);
const archive='imports/editor/fixture/';
const scene={path:'scene.json',data:encode('{"objects":[]}')};
const png=encodePng(1,1,Uint8Array.of(10,20,30,255));
function packageFixture(files,{version='0023',payload}={}) {
  const entries=files.map(file=>({...file,name:typeof file.path==='string'?encode(file.path):file.path}));
  const tableLength=16+entries.reduce((size,file)=>size+12+file.name.length,0);
  const data=payload??Uint8Array.from(entries.flatMap(file=>[...file.data]));
  const bytes=new Uint8Array(tableLength+data.length),view=new DataView(bytes.buffer);view.setUint32(0,8,true);bytes.set(encode('PKGV'+version),4);view.setUint32(12,entries.length,true);
  let cursor=16,offset=0;
  for(const file of entries){view.setUint32(cursor,file.name.length,true);cursor+=4;bytes.set(file.name,cursor);cursor+=file.name.length;
    view.setUint32(cursor,file.offset??offset,true);view.setUint32(cursor+4,file.length??file.data.length,true);cursor+=8;offset+=file.data.length;}
  bytes.set(data,tableLength);return bytes;
}

test('real pinned package export retains glTF buffer .pkg archives that upstream drops',()=>{
  const buffer={path:archive+'source/rig.pkg',data:Uint8Array.of(1,2,3,0,255)},files=[scene,buffer];
  assert(buildScenePkg(files).dropped.includes(buffer.path),'The regression must reproduce the actual pinned builder loss');
  const result=buildEditorPackage(files,buildScenePkg);assert(result.entries.includes(buffer.path));assert(!result.dropped.includes(buffer.path));
  assert.deepEqual(readEditorPackage(result.pkg).read(buffer.path),buffer.data);
});
test('archive PNG/source metadata retain exact paths and bytes while material conversion is unchanged',()=>{
  const originals=[{path:archive+'source/original.png',data:png},{path:archive+'source/empty.bin',data:new Uint8Array(0)},
    {path:archive+'conversion.json',data:encode('{"future":{"kept":true}}')}];
  const normal=[scene,{path:'materials/editor/texture.png',data:png}],baseline=buildScenePkg(normal);
  const result=buildEditorPackage([...normal,...originals],buildScenePkg),reader=readEditorPackage(result.pkg);
  assert.deepEqual(result.converted,baseline.converted);assert.deepEqual(result.dropped,baseline.dropped);assert(result.converted.includes('materials/editor/texture.tex'));
  for(const file of originals)assert.deepEqual(reader.read(file.path),file.data);
  for(const path of baseline.entries)assert.deepEqual(reader.read(path),readEditorPackage(baseline.pkg).read(path));
  assert.deepEqual(result.entries,[...baseline.entries,...originals.map(file=>file.path)].sort());
});
test('no-archive export returns the upstream result unchanged',()=>{
  const result={pkg:Uint8Array.of(7),entries:['upstream'],converted:['original'],dropped:[],future:true};let calls=0;
  const actual=buildEditorPackage([scene],files=>{calls++;assert.deepEqual(files,[scene]);return result;});
  assert.equal(calls,1);assert.equal(actual,result);assert.equal(actual.pkg,result.pkg);
});
test('only owned archive namespace files bypass the upstream builder',()=>{
  const raw={path:archive+'source/model.pkg',data:Uint8Array.of(7)},metadata={path:archive+'conversion.json',data:encode('{}')};
  const outside=[scene,{path:archive+'other.pkg',data:Uint8Array.of(9)},{path:'imports/other/source/file.pkg',data:Uint8Array.of(8)}];
  let seen;
  const result=buildEditorPackage([...outside,raw,metadata],files=>{seen=files;return buildScenePkg(files);});
  assert.deepEqual(seen,outside);assert.deepEqual(result.dropped,outside.slice(1).map(file=>file.path));
  assert.deepEqual(readEditorPackage(result.pkg).read(raw.path),raw.data);assert.deepEqual(readEditorPackage(result.pkg).read(metadata.path),metadata.data);
});
test('package and archive byte ownership survives caller and builder mutations',()=>{
  const raw={path:archive+'source/model.pkg',data:Uint8Array.of(4,5,6)},before=raw.data.slice(),normal={path:'normal.bin',data:Uint8Array.of(1,2)};
  const result=buildEditorPackage([normal,raw],files=>{files[0].data[0]=77;raw.data[0]=88;return buildScenePkg(files);});
  const reader=readEditorPackage(result.pkg);assert.deepEqual(normal.data,Uint8Array.of(1,2));assert.deepEqual(reader.read(raw.path),before);
  result.pkg.fill(0);assert.deepEqual(reader.read(raw.path),before);reader.read(raw.path).fill(0);assert.deepEqual(reader.read(raw.path),before);
  assert(Object.isFrozen(reader.paths));assert.throws(()=>reader.read('missing.bin'),/missing/i);
});
test('input unsafe paths, duplicate aliases and directory identities reject before invoking builder',()=>{
  const pathGroups=[['../escape'],['/absolute'],['a//b'],['a\\b'],['file:net'],['a\0b'],['bad\ud800'],['a','a'],['a','A'],
    ['caf\u00e9.bin','cafe\u0301.bin'],['folder','folder/child'],['Folder/a','folder/b'],['caf\u00e9/a','cafe\u0301/b']];
  for(const paths of pathGroups){let called=false;assert.throws(()=>buildEditorPackage(paths.map(path=>({path,data:Uint8Array.of(1)})),()=>{called=true;}));assert.equal(called,false);}
  for(const files of [null,{},[{path:'a',data:[1]}],[{path:'a'}],new Array(1)])assert.throws(()=>buildEditorPackage(files,buildScenePkg));
});
test('malformed upstream package and post-conversion archive collisions fail explicitly',()=>{
  const raw={path:archive+'source/model.pkg',data:Uint8Array.of(1)};
  for(const output of [{}, {pkg:Uint8Array.of(1,2,3)},Promise.resolve({})])assert.throws(()=>buildEditorPackage([scene,raw],()=>output),/package|synchronous/i);
  for(const path of [raw.path,raw.path.toUpperCase(),raw.path+'/child','Imports/unrelated.bin']){
    const pkg=packageFixture([{path,data:Uint8Array.of(3)}]);
    assert.throws(()=>buildEditorPackage([scene,raw],()=>({pkg,entries:[path],converted:[],dropped:[]})),/collision|ambiguous|duplicate/i);
  }
});
test('checked reader supports each native-supported version and subarray inputs with owned data',()=>{
  for(let version=12;version<=23;version++){
    const file={path:'folder/caf\u00e9.bin',data:Uint8Array.of(0,1,2)},pkg=packageFixture([file],{version:String(version).padStart(4,'0')}),backing=new Uint8Array(pkg.length+6);backing.set(pkg,3);
    const reader=readEditorPackage(backing.subarray(3,-3));assert.deepEqual(reader.paths,[file.path]);assert.deepEqual(reader.read(file.path),file.data);backing.fill(0);assert.deepEqual(reader.read(file.path),file.data);
  }
});
test('checked reader rejects malformed header, table, UTF-8, offsets and overlapping resource ranges',()=>{
  const file={path:'a',data:Uint8Array.of(1,2)},valid=packageFixture([file]),invalid=[];
  for(let length=0;length<valid.length;length++)invalid.push(valid.slice(0,length));
  for(const [at,value] of [[0,9],[12,0xffffffff],[16,0xffffffff],[21,0xffffffff],[25,0xffffffff]]){const bytes=valid.slice();new DataView(bytes.buffer).setUint32(at,value,true);invalid.push(bytes);}
  for(const version of ['0011','0024','00x3'])invalid.push(packageFixture([file],{version}));
  invalid.push(packageFixture([{path:Uint8Array.of(0xff),data:file.data}]));
  invalid.push(packageFixture([{path:'a',data:file.data,offset:0},{path:'b',data:file.data,offset:1}]));
  for(const paths of [['a','A'],['folder','folder/file'],['Folder/a','folder/b'],['../a']])invalid.push(packageFixture(paths.map(path=>({path,data:Uint8Array.of(1)}))));
  for(const bytes of invalid)assert.throws(()=>readEditorPackage(bytes));
  for(const value of [null,[],new ArrayBuffer(4)])assert.throws(()=>readEditorPackage(value));
  const empty=readEditorPackage(packageFixture([{path:'empty',data:new Uint8Array(0)}]));assert.deepEqual(empty.read('empty'),new Uint8Array(0));
});
