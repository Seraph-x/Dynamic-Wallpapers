import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import * as source from '../../Resources/SceneScript/resource-source.mjs';

const encode=value=>new TextEncoder().encode(value),sha256='a'.repeat(64);
const descriptor=()=>({kind:'resource',path:'materials/雪.a.json',sha256,pointer:['passes',0,'constantshadervalues','a/b.c','script'],text:'// 😀\r\nexport function update(value){return value;}'});
test('resource source descriptors preserve literal source identity and reject malformed boundary data',()=>{
 assert.equal(typeof source.validateResourceSource,'function');
 const original=descriptor(),copy=source.validateResourceSource(original);
 assert.deepEqual(copy,original);assert(Object.isFrozen(copy));assert(Object.isFrozen(copy.pointer));original.pointer[0]='mutated';assert.equal(copy.pointer[0],'passes');
 for(const change of [{kind:'inline'},{extra:1},{path:'../x'},{path:'C:/x'},{path:'/x'},{path:'a//x'},{path:'a\\x'},{path:'x\0'},{path:'\ud800'},{sha256:'A'.repeat(64)},{sha256:'a'.repeat(63)},{pointer:['passes',true]},{pointer:['passes',-1]},{pointer:['passes',0.1]},{pointer:['passes','\ud800']},{text:'\udfff'},{text:'x\0'}])assert.throws(()=>source.validateResourceSource({...descriptor(),...change}));
});
test('portable SHA256 hashes owned byte views exactly without requiring a secure context',()=>{
 assert.equal(typeof source.resourceSHA256,'function');
 for(const bytes of [encode(''),encode('abc'),encode('雪😀'),encode('a'.repeat(1000000)),Buffer.from([1,2,3,4]).subarray(1,3)])assert.equal(source.resourceSHA256(bytes),createHash('sha256').update(bytes).digest('hex'));
});
test('resource origin registry binds exact original bytes and authenticated structural wrapper identities',()=>{
 assert.equal(typeof source.createResourceOrigins,'function');
 const origins=source.createResourceOrigins(),raw='{/*keep*/"passes":[{"shader":"generic4","constantshadervalues":{"Color":{"value":"1 0 0","script":"export function update(v){return v;}"},"Unknown":{"value":1,"script":"unknown"}}}],"future":{"script":"opaque"}}';
 const doc={passes:[{shader:'generic4',constantshadervalues:{Color:{value:'1 0 0',script:'export function update(v){return v;}'},Unknown:{value:1,script:'unknown'}}}],future:{script:'opaque'}},bytes=encode(raw);
 origins.capture('materials/a.json',bytes,doc,'material');bytes.fill(32);
 const wrapper=doc.passes[0].constantshadervalues.Color,captured=origins.script(wrapper,'tint');
 assert.equal(captured.source.sha256,createHash('sha256').update(raw).digest('hex'));assert.equal(captured.source.text,wrapper.script);
 assert.deepEqual(captured.source.pointer,['passes',0,'constantshadervalues','Color','script']);assert.equal(captured.valueKind,'vector3');
 assert.equal(origins.script({...wrapper},'tint'),undefined);assert.equal(origins.script(doc.passes[0].constantshadervalues.Unknown,'tint'),undefined);assert.equal(origins.script(doc.future,'effect'),undefined);
 assert(Object.isFrozen(captured));assert(Object.isFrozen(captured.source));
 wrapper.script='changed';assert.throws(()=>origins.script(wrapper,'tint'),/source.*changed|origin/i);
});
test('duplicate/bound resource wrappers and unsupported passes never acquire executable origin metadata',()=>{
 const origins=source.createResourceOrigins();
 for(const raw of ['{"passes":[{"shader":"generic4","constantshadervalues":{"Alpha":{"value":1,"script":"a","script":"b"}}}]}','{"passes":[{"shader":"generic4","constantshadervalues":{"Alpha":{"value":1,"script":"a","user":"bound"}}}]}','{"passes":[{}, {"shader":"generic4","constantshadervalues":{"Alpha":{"value":1,"script":"later"}}}]}']){
  const doc=JSON.parse(raw);origins.capture('materials/a.json',encode(raw),doc,'material');
  const wrapper=doc.passes.at(-1).constantshadervalues.Alpha;assert.equal(origins.script(wrapper,'tint'),undefined);
 }
});
