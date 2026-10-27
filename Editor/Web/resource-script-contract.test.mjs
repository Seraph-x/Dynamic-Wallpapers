import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectResourceScripts, patchResourceScript } from '../../Resources/SceneScript/resource-contract.mjs';
const encode=text=>new TextEncoder().encode(text),decode=bytes=>new TextDecoder('utf-8',{ignoreBOM:true}).decode(bytes);
const material=(raw,consumers=[{kind:'effect',layerId:1,effect:0,pass:0}])=>({path:'materials/a.json',kind:'material',bytes:encode(raw),consumers});
const find=(report,key)=>report.records.find(record=>record.anchor.at(-1)===key&&record.registered);

test('material registry exposes exact consumed scalar/vector anchors and preserves unknown source metadata',()=>{
 const input=material('{"passes":[{"shader":"effects/test","constantshadervalues":{"Strength":{"value":1,"script":"old","future":9007199254740993},"Vector":{"value":"1 2 3 4"},"Bound":{"value":1,"script":"old","user":"slider"}}}],"future":{"script":"metadata"}}');
 const report=inspectResourceScripts(input);
 assert.equal(find(report,'Strength').valueKind,'scalar');assert.equal(find(report,'Vector').valueKind,'vector4');
 assert.equal(find(report,'Bound').editable,false);assert.match(find(report,'Bound').reason,/binding/i);
 assert(report.records.some(record=>!record.registered&&record.source==='metadata'));
 const edited=patchResourceScript({...input,anchor:['passes',0,'constantshadervalues','Strength'],type:'set',source:'雪\r\n😀'});
 assert.equal(decode(edited),decode(input.bytes).replace('"old"','"雪\\r\\n😀"'));
 assert.match(decode(edited),/9007199254740993/);
});

test('first-pass and actual generic tint consumption restrict unsupported fields visibly',()=>{
 const raw='{"passes":[{"shader":"generic4","constantshadervalues":{"Color":{"value":"1 0 0","script":"s"},"Alpha":1,"Ignored":{"value":1,"script":"ignored"}}},{"constantshadervalues":{"Later":{"value":1,"script":"later"}}}]}';
 const report=inspectResourceScripts(material(raw,[{kind:'tint',layerId:1}]));
 assert.equal(find(report,'Color').editable,true);assert.equal(find(report,'Alpha').editable,true);
 assert(report.records.some(record=>record.source==='ignored'&&!record.editable&&record.reason));
 assert(report.records.some(record=>record.source==='later'&&!record.editable&&record.reason));
 const unconsumed=inspectResourceScripts(material(raw,[]));assert(unconsumed.records.every(record=>!record.editable));
 assert.throws(()=>patchResourceScript({...material(raw,[]),anchor:['passes',0,'constantshadervalues','Alpha'],type:'set',source:'s'}),/consum|referenc/i);
});

test('typed external particle child overrides and emitter rate are registered without claiming other JSON scripts',()=>{
 const input={path:'particles/a.json',kind:'particle',consumers:[{kind:'particle',layerId:1}],bytes:encode('{"emitter":[{"rate":{"value":3,"script":"rate"},"future":{"script":"opaque"}}],"children":[{"name":"particles/child.json","instanceoverride":{"alpha":{"value":1,"script":"alpha"},"colorn":{"value":"1 0 0","script":"color"},"controlpoint1":{"value":"1 2 3","script":"unknown"}}}]}')};
 const report=inspectResourceScripts(input);
 assert.equal(find(report,'rate').editable,true);assert.equal(find(report,'alpha').editable,true);assert.equal(find(report,'colorn').valueKind,'vector3');
 for(const source of ['opaque','unknown'])assert(report.records.some(record=>record.source===source&&!record.registered&&record.reason));
 const removed=patchResourceScript({...input,anchor:['children',0,'instanceoverride','alpha'],type:'remove'});
 assert.equal(decode(removed),decode(input.bytes).replace(',"script":"alpha"',''));
});

test('set wraps primitive/array bases losslessly and unchanged/remove-noop preserve original bytes',()=>{
 for(const value of ['1e+0','[1, 2, 3]','"1 2"']){
  const input=material('{"passes":[{"shader":"effects/test","constantshadervalues":{"X":'+value+'}}]}'),anchor=['passes',0,'constantshadervalues','X'];
  assert.deepEqual(patchResourceScript({...input,anchor,type:'remove'}),input.bytes);
  const edited=patchResourceScript({...input,anchor,type:'set',source:''});
  assert(decode(edited).includes('{"value":'+value+',"script":""}'));
 }
 const input=material('{"passes":[{"shader":"effects/test","constantshadervalues":{"X":{"value":1,"script":"\\u0073"}}}]}');
 assert.deepEqual(patchResourceScript({...input,anchor:['passes',0,'constantshadervalues','X'],type:'set',source:'s'}),input.bytes);
});

test('ambiguous paths, malformed bases/source and invalid edits fail without rewriting imported resources',()=>{
 for(const raw of [
  '{"passes":[{"constantshadervalues":{"X":{"value":1,"script":"a","script":"b"}}}]}',
  '{"passes":[{"constantshadervalues":{"X":{"value":1,"script":3}}}]}',
  '{"passes":[{"constantshadervalues":{"X":{"value":1e999,"script":"a"}}}]}',
  '{"passes":[{"constantshadervalues":{"X":{"script":"a"}}}]}']){
  const input=material(raw);assert(inspectResourceScripts(input).records.some(record=>!record.editable));
  assert.throws(()=>patchResourceScript({...input,anchor:['passes',0,'constantshadervalues','X'],type:'set',source:'new'}));
  assert.equal(decode(input.bytes),raw);
 }
 const input=material('{"passes":[{"constantshadervalues":{"X":1}}]}');
 assert.throws(()=>patchResourceScript({...input,anchor:['future'],type:'set',source:'s'}),/anchor|target/i);
 assert.throws(()=>patchResourceScript({...input,anchor:['passes',0,'constantshadervalues','X'],type:'merge',source:'s'}),/edit/i);
});

test('ambiguous source occurrences stay visible and material vector comments remain exact when wrapped',()=>{
 const duplicate=inspectResourceScripts(material('{"passes":[{"shader":"effects/test","constantshadervalues":{"X":{"value":1,"script":"first","script":"second"}}}]}'));
 assert.deepEqual(duplicate.records.filter(record=>record.source).map(record=>record.source).sort(),['first','second']);
 assert(duplicate.records.every(record=>!record.editable));
 const input=material('{"passes":[{"shader":"effects/test","constantshadervalues":{"X":[1,/*keep*/2,3]}}]}');
 const edited=patchResourceScript({...input,anchor:['passes',0,'constantshadervalues','X'],type:'set',source:'s'});
 assert(decode(edited).includes('{"value":[1,/*keep*/2,3],"script":"s"}'));
});

test('generic tint source contracts require actual scalar and vector3 sink shapes',()=>{
 const values={Alpha:'1 2 3',Brightness:'1 2',Color:'1 2 3 4'},constants=Object.fromEntries(Object.entries(values).map(([key,value])=>[key,{value,script:'s'}]));
 const input=material(JSON.stringify({passes:[{shader:'generic4',constantshadervalues:constants}]}),[{kind:'tint',layerId:1}]),report=inspectResourceScripts(input);
 for(const key of Object.keys(values)){const record=find(report,key);assert.equal(record.editable,false,key);assert.match(record.reason,/scalar|vector3|base/i);assert.throws(()=>patchResourceScript({...input,anchor:record.anchor,type:'set',source:'s'}));}
});

test('prototype-looking constant names cannot inherit a generic tint registration',()=>{
 const input=material('{"passes":[{"shader":"generic4","constantshadervalues":{"constructor":{"value":1,"script":"s"}}}]}',[{kind:'tint',layerId:1}]);
 const record=find(inspectResourceScripts(input),'constructor');assert.equal(record.editable,false);assert.match(record.reason,/consum/i);
});
