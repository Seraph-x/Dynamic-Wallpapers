import test from 'node:test';
import assert from 'node:assert/strict';
import { discoverResourceScripts, discoverEditorResourceScripts } from './resource-scripts.mjs';
import { createMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';
import { modelSpec } from './model-fixtures.mjs';
const encode=value=>new TextEncoder().encode(typeof value==='string'?value:JSON.stringify(value));
const scene={title:'Resources',entry:'scene.json',project:{type:'scene'},scene:{objects:[
 {id:1,image:'models/a.json',effects:[{file:'effects/a.json'}],particle:'particles/root.json'},
 {id:2,image:'models/a.json'}]}};
function assets(){return new Map([
 ['models/a.json',encode({material:'materials/shared.json'})],
 ['effects/a.json',encode({passes:[{material:'materials/effect.data'}]})],
 ['materials/shared.json',encode({passes:[{shader:'generic4',constantshadervalues:{Alpha:{value:1,script:'shared'}}}]})],
 ['materials/effect.data',encode({passes:[{shader:'effects/owned',constantshadervalues:{Strength:{value:1,script:'effect'}}}]})],
 ['particles/root.json',encode({material:'materials/particle.json',emitter:[{rate:{value:3,script:'rate'}}],children:[{name:'particles/child.json',instanceoverride:{alpha:{value:1,script:'child'}}}]})],
 ['particles/child.json',encode({emitter:[{rate:2}]})],
 ['materials/particle.json',encode({passes:[{shader:'particles/owned',constantshadervalues:{Color:{value:'1 0 0',script:'particle'}}}]})],
 ['unreferenced.json',encode({future:{script:'opaque'}})],
 ['standalone.js',encode('globalThis.__resourceDiscoveryRan=true;')]
]);}

test('discovery follows model/effect/particle references and retains shared consumers and unsupported assets',async()=>{
 const files=assets(),reads=new Map();
 const report=await discoverResourceScripts({snapshot:scene,paths:[...files.keys()],read:async path=>{reads.set(path,(reads.get(path)??0)+1);return files.get(path)??null;}});
 assert.equal(report.failures.length,0);assert.equal(report.scope,'resource-source-discovery');
 const shared=report.records.find(record=>record.source==='shared');assert.equal(shared.editable,true);assert.deepEqual(shared.consumers.map(value=>value.layerId).sort(),[1,2]);
 for(const source of ['effect','rate','child','particle'])assert(report.records.some(record=>record.source===source&&record.editable),source);
 assert(report.records.some(record=>record.source==='opaque'&&!record.editable&&record.reason));
 assert(report.records.some(record=>record.path==='standalone.js'&&!record.editable&&record.reason));
 assert.equal(Object.hasOwn(globalThis,'__resourceDiscoveryRan'),false);
 assert([...reads.values()].every(count=>count===1));
 assert(Object.isFrozen(shared));assert(Object.isFrozen(shared.anchor));
});

test('real MDL material references are read without renderer execution',async()=>{
 const spec=modelSpec(),mdl=writeMdlDoc(createMdlDoc(spec)),material=spec.meshes[0].material;
 const files=new Map([['rig.mdl',mdl],[material,encode({passes:[{shader:'effects/owned',constantshadervalues:{X:{value:1,script:'mdl'}}}]})]]);
 const snapshot={...scene,scene:{objects:[{id:5,model:'rig.mdl'}]}};
 const report=await discoverResourceScripts({snapshot,paths:[...files.keys()],read:async path=>files.get(path)});
 assert.equal(report.failures.length,0);assert(report.records.some(record=>record.source==='mdl'&&record.consumers[0].kind==='mesh'));
});

test('inventory aliases and file/directory conflicts reject before reads; missing/cyclic/malformed resources remain visible',async()=>{
 let reads=0;
 for(const paths of [['a.json','A.JSON'],['a','a/b.json'],['../escape'],['a.json','a.json']])await assert.rejects(discoverResourceScripts({snapshot:scene,paths,read:async()=>{reads++;}}),/path|alias|collision|duplicate|ambiguous/i);
 assert.equal(reads,0);
 const files=assets();files.set('particles/child.json',encode({children:[{name:'particles/root.json'}]}));files.set('materials/shared.json',encode('{bad'));
 const report=await discoverResourceScripts({snapshot:scene,paths:[...files.keys(),'missing.json'],read:async path=>files.get(path)??null});
 assert(report.failures.some(failure=>/cycl/i.test(failure.message)));
 assert.equal(report.failures.filter(failure=>failure.path==='materials/shared.json').length,1);
 assert(report.failures.some(failure=>failure.path==='missing.json'));
 assert(report.records.some(record=>record.path==='materials/shared.json'&&!record.editable&&record.reason));
});

test('opaque read failures and mismatched override hashes cannot be mistaken for a complete scan',async()=>{
 const files=assets(),snapshot=structuredClone(scene);snapshot.resourceOverrides={'materials/shared.json':'a'.repeat(64)};
 const report=await discoverResourceScripts({snapshot,paths:[...files.keys()],read:async path=>{if(path==='effects/a.json')throw new Error('Permission denied');return files.get(path);}});
 assert(report.failures.some(failure=>/Permission denied/.test(failure.message)));
 assert(report.failures.some(failure=>/hash|corrupt/i.test(failure.message)));
 assert(!report.records.some(record=>record.path==='materials/shared.json'&&record.editable));
});

test('prototype-looking logical file names never read inherited override dictionary members',async()=>{
 const snapshot={...scene,resourceOverrides:{},scene:{objects:[{id:1,image:'model.json'}]}},files=new Map([
  ['model.json',encode({material:'constructor'})],['constructor',encode({passes:[{shader:'effects/test',constantshadervalues:{X:{value:1,script:'s'}}}]})]
 ]);
 const report=await discoverResourceScripts({snapshot,paths:[...files.keys()],read:async path=>files.get(path)});
 assert.equal(report.failures.length,0);const record=report.records.find(value=>value.path==='constructor'&&value.registered);
 assert.equal(record.editable,true);assert.equal(record.overrideVersion,undefined);
});

test('alternate MDL skin material sources stay visible without being claimed as consumed',async()=>{
 const spec=modelSpec(),doc=createMdlDoc(spec);doc.skinCount=2;
 for(const mesh of doc.meshes)mesh.materials.push('materials/alternate.json');
 const files=new Map([['rig.mdl',writeMdlDoc(doc)],
  [spec.meshes[0].material,encode({passes:[{shader:'effects/owned',constantshadervalues:{X:{value:1,script:'primary'}}}]})],
  ['materials/alternate.json',encode({passes:[{shader:'effects/owned',constantshadervalues:{X:{value:1,script:'alternate'}}}]})]
 ]);
 const report=await discoverResourceScripts({snapshot:{...scene,scene:{objects:[{id:1,model:'rig.mdl'}]}},paths:[...files.keys()],read:async path=>files.get(path)});
 assert.equal(report.failures.length,0);assert.equal(report.records.find(record=>record.source==='primary').editable,true);
 const alternate=report.records.find(record=>record.source==='alternate');assert.equal(alternate.editable,false);assert.match(alternate.reason,/skin|consum/i);
});

test('unconsumed glTF and JSONC source metadata is visible read-only without execution',async()=>{
 const files=new Map([['imports/editor/owned/source/source.gltf',encode({asset:{version:'2.0'},extras:{script:'gltf metadata'}})],['notes.jsonc',encode('{/*keep*/"future":{"script":"jsonc metadata"},}')]]);
 const report=await discoverResourceScripts({snapshot:{...scene,scene:{objects:[]}},paths:[...files.keys()],read:async path=>files.get(path)});
 assert.equal(report.failures.length,0);
 for(const source of ['gltf metadata','jsonc metadata'])assert(report.records.some(record=>record.source===source&&!record.editable&&!record.registered&&record.reason),source);
});

test('Editor-bound discovery rejects owner replacement even when snapshot bytes are identical',async()=>{
 const files=assets(),before={snapshot:()=>structuredClone(scene)};let release,started;
 const gate=new Promise(resolve=>{release=resolve;}),entered=new Promise(resolve=>{started=resolve;});
 const editor={document:before,closed:false,async resourcePaths(){return [...files.keys()];},async readResource(path){if(path==='models/a.json'){started();await gate;}return files.get(path);}};
 const pending=discoverEditorResourceScripts(editor);await entered;editor.document={snapshot:()=>structuredClone(scene)};release();
 await assert.rejects(pending,/changed|stale/i);
});
