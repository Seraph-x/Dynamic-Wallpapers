import test from 'node:test';
import assert from 'node:assert/strict';
import { parseResourceJSON, jsonNodeAt, jsonMembers, setJSONStringMember, removeJSONMember, replaceJSONValue } from '../../Resources/SceneScript/json-spans.mjs';
const bytes = text => new TextEncoder().encode(text);
const text = value => new TextDecoder('utf-8', {ignoreBOM:true}).decode(value);

test('span edits retain BOM, comments, CRLF, huge numbers, duplicate unknown keys and escaped source keys', () => {
  const raw = '\ufeff{\r\n /*keep*/ "passes": [{"constantshadervalues":{"a/b.c":{"value":1e+0,"scr\\u0069pt":"old","future":9007199254740993,"opaque":1,"opaque":2}}}],\r\n "future":"// ,} /* not comments */",\r\n}';
  const parsed = parseResourceJSON(bytes(raw), {mode:'jsonc'}), anchor = ['passes',0,'constantshadervalues','a/b.c'];
  assert.equal(text(setJSONStringMember(parsed, anchor, 'script', '雪\r\n😀')), raw.replace('"old"', '"雪\\r\\n😀"'));
  assert.equal(text(setJSONStringMember(parsed, anchor, 'script', 'old')), raw);
  assert.equal(jsonNodeAt(parsed,[...anchor,'value']).value, 1);
  assert.equal(jsonMembers(parsed, 'script')[0].path.at(-1), 'script');
  assert.equal(text(parsed.bytes()), raw);
});

test('add/remove patches only owned member and separator spans, including trailing-comma objects', () => {
  for (const raw of ['{ "a":1, /*stay*/ "script":"s", /*next*/ "z":2 }','{"script":"s", /*stay*/ "z":2}', '{"z":2, /*stay*/ "script":"s"}', '{ /*stay*/ "script":"s" }','{ "script":"s", /*stay*/ }']) {
    const parsed = parseResourceJSON(bytes(raw), {mode:'jsonc'}), removed = text(removeJSONMember(parsed, [], 'script'));
    assert(removed.includes('/*stay*/'));
    assert(!jsonNodeAt(parseResourceJSON(bytes(removed),{mode:'jsonc'}), ['script']));
    assert.equal(text(removeJSONMember(parseResourceJSON(bytes(removed),{mode:'jsonc'}), [], 'script')), removed);
  }
  for (const raw of ['{}','{/*keep*/}','{"x":1}','{"x":1 /*keep*/}','{"x":1, /*keep*/}']) {
    const parsed = parseResourceJSON(bytes(raw), {mode:'jsonc'}), added = setJSONStringMember(parsed, [], 'script', '');
    assert.equal(jsonNodeAt(parseResourceJSON(added,{mode:'jsonc'}),['script']).value, '');
    if(raw.includes('/*keep*/'))assert(text(added).includes('/*keep*/'));
  }
});

test('duplicate selected keys and path ancestors are ambiguous while unknown duplicates stay lossless', () => {
  for (const raw of ['{"x":{"script":"a","script":"b"}}','{"x":{},"x":{"script":"b"}}']) {
    const parsed = parseResourceJSON(bytes(raw));
    assert.throws(() => setJSONStringMember(parsed,['x'],'script','replacement'), /ambiguous|duplicate/i);
    assert.equal(text(parsed.bytes()),raw);
    assert(jsonMembers(parsed,'script').every(record=>record.ambiguous));
  }
  const parsed=parseResourceJSON(bytes('{"future":1,"future":2,"x":0}'));
  assert.equal(text(replaceJSONValue(parsed,['x'],'{"value":0,"script":"s"}')),'{"future":1,"future":2,"x":{"value":0,"script":"s"}}');
});

test('lexer enforces complete strict JSON and explicit JSONC without executing or rewriting input', () => {
  for(const raw of ['', '{', '[1,]', '{"a":1,}', '{"a":01}', '{"a":1e}', '{"a":NaN}', '{"a":"bad\n"}', '{"a":"\\x20"}', '{"a":1} false', '{/*x*/"a":1}', '{"a":undefined}', '[1 2]']) assert.throws(()=>parseResourceJSON(bytes(raw)));
  for(const raw of ['{/*unterminated','{"a":1,,}','[1,,]','{"a":/*x*/}']) assert.throws(()=>parseResourceJSON(bytes(raw),{mode:'jsonc'}));
  assert.throws(()=>parseResourceJSON(new Uint8Array([0xff])),/UTF|encoding|encoded/i);
  assert.throws(()=>parseResourceJSON(bytes('{}'),{mode:'future'}),/mode/i);
  const parsed=parseResourceJSON(bytes('{"__proto__":{"script":"globalThis.__lexerRan=true;"}}'));
  assert.equal(jsonMembers(parsed,'script')[0].path[0],'__proto__');
  assert.equal(Object.hasOwn(globalThis,'__lexerRan'),false);
  assert.throws(()=>setJSONStringMember(parsed, ['__proto__'], 'script', '\ud800'),/Unicode/i);
  assert.throws(()=>replaceJSONValue(parsed, ['__proto__'], '{};globalThis.__lexerRan=true'),/JSON|trailing|token/i);
});

test('owned parse trees cannot be forged or mutated and traversal has no artificial nesting limit', () => {
  const input=bytes('{"script":"original"}'), parsed=parseResourceJSON(input);input.fill(32);
  assert.equal(jsonNodeAt(parsed,['script']).value,'original');
  assert.throws(()=>{parsed.root.members[0].key='changed';});
  assert.throws(()=>setJSONStringMember({...parsed},[],'script','forged'),/document/i);
  const nested='{ "a":'.repeat(12000)+'{"script":"deep"}'+'}'.repeat(12000), tree=parseResourceJSON(bytes(nested));
  const found=jsonMembers(tree,'script');assert.equal(found.length,1);assert.equal(found[0].path.length,12001);
  assert.equal(jsonNodeAt(tree,found[0].path).value,'deep');
});

test('Buffer inputs and returned bytes have independent ownership',()=>{
 const input=Buffer.from('{"script":"s"}'),parsed=parseResourceJSON(input),copy=parsed.bytes();
 input.fill(32);copy.fill(32);assert.equal(text(parsed.bytes()),'{"script":"s"}');
});

test('escaped lone Unicode surrogates reject in every string while valid pairs and JSON NUL remain lossless',()=>{
 for(const raw of [String.raw`{"future":"\ud800"}`,String.raw`{"\udfff":1}`,String.raw`["\ud800x"]`,String.raw`{"script":"\udfff\ud800"}`]) {
  assert.throws(()=>parseResourceJSON(bytes(raw)),/Unicode/i);
 }
 const raw=String.raw`{"future":"\ud83d\ude00\u0000","\ud83d\ude00":"unchanged"}`;
 assert.equal(text(parseResourceJSON(bytes(raw)).bytes()),raw);
});

test('wide JSON arrays do not depend on a JavaScript spread argument limit',()=>{
 const parsed=parseResourceJSON(bytes('['+'0,'.repeat(140000)+'0]'));
 assert.equal(parsed.root.items.length,140001);assert.equal(parsed.root.items.at(-1).value,0);
});
