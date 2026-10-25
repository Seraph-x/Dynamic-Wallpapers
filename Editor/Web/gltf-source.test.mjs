import test from 'node:test';
import assert from 'node:assert/strict';
import * as source from './gltf-source.mjs';
import { gltfSource,glbSource,glbBytes } from './gltf-fixtures.mjs';
const parse=input=>source.parseGltfSource(input);
test('source decoding owns originals, resolves exact relative URIs and never guesses a basename',()=>{
  const input=gltfSource({asset:{version:'2.0'},buffers:[{uri:'sub/data.bin',byteLength:4}]},[{path:'sub/data.bin',bytes:Uint8Array.of(1,2,3,4)}]);
  const parsed=parse(input);input.files[1].bytes.fill(9);assert.deepEqual([...parsed.buffers[0]],[1,2,3,4]);assert.equal(parsed.json.asset.version,'2.0');
  assert.deepEqual([...parsed.readURI('sub/data.bin')],[1,2,3,4]);assert.throws(()=>parsed.readURI('other/data.bin'),/missing/i);
});
test('data URI buffers preserve raw bytes, including percent-encoded non-UTF8 bytes',()=>{
  for(const uri of ['data:application/octet-stream;base64,/wABAg==','data:application/octet-stream,%FF%00%01%02']){
    const parsed=parse(gltfSource({asset:{version:'2.0'},buffers:[{uri,byteLength:4}]}));assert.deepEqual([...parsed.buffers[0]],[255,0,1,2]);
  }
});
test('GLB validates exact header/chunks and retains unknown chunk bytes in the source archive',()=>{
  const input=glbSource({asset:{version:'2.0'},buffers:[{byteLength:3}]},Uint8Array.of(1,2,3),[{type:0x12345678,bytes:Uint8Array.of(7,8,9,0)}]);
  const original=input.files[0].bytes.slice(),parsed=parse(input);assert.deepEqual([...parsed.buffers[0]],[1,2,3]);assert.equal(parsed.unknownChunks.length,1);assert.deepEqual(parsed.files[0].bytes,original);
  for(const change of [b=>new DataView(b.buffer).setUint32(8,b.length-4,true),b=>new DataView(b.buffer).setUint32(4,1,true),b=>new DataView(b.buffer).setUint32(12,7,true),b=>new DataView(b.buffer).setUint32(16,0x004e4942,true),b=>new DataView(b.buffer).setUint32(12,b.length,true)]){
    const bytes=original.slice();change(bytes);assert.throws(()=>parse({entry:'model.glb',files:[{path:'model.glb',bytes}]}));
  }
  assert.throws(()=>parse(glbSource({asset:{version:'2.0'},buffers:[{byteLength:8}]},Uint8Array.of(1,2,3,4))),/buffer|length/i);
});
test('GLB duplicate JSON/BIN chunks and incomplete tails reject explicitly',()=>{
  for(const type of [0x4e4f534a,0x004e4942])assert.throws(()=>parse(glbSource({asset:{version:'2.0'}},new Uint8Array(4),[{type,bytes:new Uint8Array(4)}])),/chunk|duplicate|order/i);
  const bytes=glbBytes({asset:{version:'2.0'}}),tail=new Uint8Array(bytes.length+1);tail.set(bytes);new DataView(tail.buffer).setUint32(8,tail.length,true);assert.throws(()=>parse({entry:'model.glb',files:[{path:'model.glb',bytes:tail}]}));
});
test('source rejects external/traversal/query/invalid URI access and ambiguous archive paths',()=>{
  for(const uri of ['../private.bin','%2e%2e/private.bin','/private.bin','https://example.invalid/a.bin','file:///a.bin','a\\b.bin','a%2Fb.bin','a%5Cb.bin','x%00.bin','a.bin?q=1','a.bin#part','bad%zz.bin']){
    assert.throws(()=>parse(gltfSource({asset:{version:'2.0'},buffers:[{uri,byteLength:4}]})));
  }
  for(const paths of [['A.bin','a.bin'],['café.bin','cafe\u0301.bin'],['Tex/a.bin','tex/b.bin'],['sub','sub/file.bin']]){
    assert.throws(()=>parse(gltfSource({asset:{version:'2.0'}},paths.map(path=>({path,bytes:new Uint8Array(4)})))),/ambiguous|collision/i);
  }
});
test('source validates metadata, buffer lengths, views and UTF8 without mutating input',()=>{
  for(const json of [[],{}, {asset:{version:'2.1'}},{asset:{version:'2.0',minVersion:'2.1'}},{asset:{version:'2.0'},buffers:[{uri:'data:;base64,AAAA',byteLength:4}]},{asset:{version:'2.0'},buffers:[{uri:'data:;base64,AAAA',byteLength:-1}]}])assert.throws(()=>parse(gltfSource(json)));
  const input=gltfSource({asset:{version:'2.0'},buffers:[{uri:'data:;base64,AQIDBA==',byteLength:4}],bufferViews:[{buffer:0,byteOffset:3,byteLength:2}]});assert.throws(()=>parse(input),/view|bounds|range/i);
  assert.throws(()=>parse({entry:'model.gltf',files:[{path:'model.gltf',bytes:Uint8Array.of(0xff,0xfe)}]}));
  const nested={entry:'models/model.gltf',files:[{path:'models/model.gltf',bytes:new TextEncoder().encode('{"asset":{"version":"2.0"},"buffers":[{"uri":"data.bin","byteLength":1}]}')},{path:'models/data.bin',bytes:Uint8Array.of(42)}]};assert.equal(parse(nested).buffers[0][0],42);
});
test('local paths reject raw and decoded controls but percent names are decoded only once',()=>{
 for(const uri of ['a\n.bin','a\t.bin','a\x7f.bin','a%0A.bin','a%09.bin','a%1F.bin','a%7F.bin'])assert.throws(()=>source.gltfLocalURI(uri,'model.gltf'),/URI|path/i);
 assert.equal(source.gltfLocalURI('%252e%252e/file.bin','model.gltf'),'%2e%2e/file.bin');assert.equal(source.gltfLocalURI('100%25.bin','model.gltf'),'100%.bin');
});
test('selected glTF/GLB entry type must match its exact container',()=>{
 const plain=gltfSource();plain.entry=plain.files[0].path='wrong.glb';assert.throws(()=>parse(plain),/GLB|container/i);
 const binary=glbSource({asset:{version:'2.0'}});binary.entry=binary.files[0].path='wrong.gltf';assert.throws(()=>parse(binary),/glTF|container/i);
});
