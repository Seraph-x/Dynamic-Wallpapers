import test from 'node:test';
import assert from 'node:assert/strict';
import { readEventMetadata, patchEventMetadata, validateEventName } from './event-json.mjs';

const clip={frameCount:8,fps:4};
const metadata=raw=>readEventMetadata({json:raw,time:0.5},clip);
test('patches only selected value spans, preserving escaped keys and all unknown JSON lexemes',()=>{
 const raw=' \n{ "fr\\u0061me" : 2, "n\\u0061me" : "mi\\u0064dle", "future":900719925474099312345, "future":[true,null,{"name":"untouched","a":-1.20e+99}] }\t';
 const value=metadata(raw);assert.equal(value.frame,2);assert.equal(value.name,'middle');
 assert.equal(patchEventMetadata(raw,{frame:3,name:'fire "🌟"'}),raw.replace(': 2',': 3').replace('"mi\\u0064dle"','"fire \\"🌟\\""'));
 assert.equal(patchEventMetadata(raw,{frame:2,name:'middle'}),raw);
});
test('rejects duplicate known decoded keys but accepts unknown duplicates and nested known keys',()=>{
 for(const raw of ['{"frame":0,"frame":2,"name":"x"}','{"frame":2,"name":"a","n\\u0061me":"b"}'])assert.throws(()=>metadata(raw),/duplicate/i);
 assert.equal(metadata('{"frame":2,"name":"x","a":1,"a":2,"nested":{"frame":8,"name":false}}').frame,2);
});
test('requires valid JSON object, integer native-range frame, valid name and consistent time',()=>{
 for(const raw of ['null','[]','{"frame":2,}','{"frame":2,"name":"x","unknown":01}','{"frame":2,"name":"x"} trailing','{"frame":2,"name":"x","unknown":"bad\ntext"}','{"frame":"2","name":"x"}','{"frame":2.5,"name":"x"}','{"frame":9,"name":"x"}','{"frame":-1,"name":"x"}','{"frame":2}','{"frame":2,"name":7}','{"frame":2,"name":"\\ud800"}','{"frame":2,"name":"a\\u0000b"}'])assert.throws(()=>metadata(raw),/event|JSON|name|frame/i,raw);
 assert.throws(()=>readEventMetadata({json:'{"frame":2,"name":"x"}',time:0.7},clip),/time/i);
 assert.equal(metadata('{"frame":2e0,"name":""}').name,'');
});
test('valid Unicode names have no artificial length cap and empty names are allowed',()=>{
 for(const name of ['', '\ufeff🌟汉字', 'x'.repeat(100000)])assert.equal(validateEventName(name),name);
 for(const name of [null,4,'a\0b','\ud800','\udfff'])assert.throws(()=>validateEventName(name),/name/i);
});
