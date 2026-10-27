import test from 'node:test';
import assert from 'node:assert/strict';
import { SceneDocument } from './document.mjs';

const initial=()=>({title:'Properties',entry:'scene.json',scene:{objects:[],future:{keep:true}},project:{type:'scene',file:'scene.json',future:[1,2],general:{future:true,properties:{speed:{type:'slider',text:'Speed',value:1,min:0,max:3,step:0.1,future:{keep:true}},conditional:{type:'bool',value:true,condition:'speed'},file:{type:'file',value:'x.png'}}},preset:{presetOnly:'hello'}}});
const create=(doc,name,declaration)=>doc.propertyDefinition({type:'create',name,declaration});

test('create all five declarations, preserve unknown fields, undo/redo and reopen saved JSON',()=>{
 const input=initial(),doc=new SceneDocument(input);
 const declarations={enabled:{type:'bool',value:false},color:{type:'color',value:'0 0.5 1'},text:{type:'textinput',value:'雪\nline'},choice:{type:'combo',value:'a',options:[{label:'A',value:'a'},{label:'B',value:'b'}]},unbounded:{type:'slider',value:-10}};
 for(const [name,declaration]of Object.entries(declarations))create(doc,name,declaration);
 for(const [name,declaration]of Object.entries(declarations))assert.deepEqual(doc.snapshot().project.general.properties[name],declaration);
 assert.deepEqual(doc.snapshot().scene,input.scene);assert.equal(doc.snapshot().project.general.future,true);
 const authored=doc.snapshot();doc.markSaved();assert(!doc.dirty);
 for(let i=0;i<5;i++)doc.undo();assert.deepEqual(doc.snapshot(),input);
 for(let i=0;i<5;i++)doc.redo();assert.deepEqual(doc.snapshot(),authored);assert(!doc.dirty);
 const reopened=new SceneDocument(JSON.parse(JSON.stringify(authored)));assert.deepEqual(reopened.snapshot(),authored);
 assert.deepEqual(input,initial());
});
test('update, copy and delete preserve unknown metadata and references with atomic history',()=>{
 const doc=new SceneDocument(initial());
 doc.propertyDefinition({type:'update',name:'speed',patch:{text:'速度',value:2,order:7,min:undefined}});
 const updated=doc.snapshot();assert(!Object.hasOwn(updated.project.general.properties.speed,'min'));assert.deepEqual(updated.project.general.properties.speed.future,{keep:true});
 doc.propertyDefinition({type:'copy',name:'speed',newName:'speedCopy'});
 assert.deepEqual(doc.snapshot().project.general.properties.speedCopy,updated.project.general.properties.speed);
 doc.propertyDefinition({type:'delete',name:'speed'});assert(!Object.hasOwn(doc.snapshot().project.general.properties,'speed'));
 assert.deepEqual(doc.snapshot().project.preset,initial().project.preset);assert.deepEqual(doc.snapshot().scene,initial().scene);
 doc.undo();doc.undo();assert.deepEqual(doc.snapshot(),updated);doc.undo();assert.deepEqual(doc.snapshot(),initial());
});
test('invalid edits reject atomically without creating history or changing key/type',()=>{
 const doc=new SceneDocument(initial()),before=doc.snapshot();
 const edits=[
  {type:'create',name:'',declaration:{type:'bool',value:true}},
  ...['speed','presetOnly','__proto__'].map(name=>({type:'create',name,declaration:{type:'bool',value:true}})),
  {type:'update',name:'speed',patch:{type:'bool',value:true}},
  {type:'update',name:'speed',patch:{future:'changed'}},
  ...[{value:NaN},{min:4},{step:0},{value:'2'},{text:null}].map(patch=>({type:'update',name:'speed',patch})),
  ...['conditional','file','presetOnly','missing'].map(name=>({type:'delete',name})),
  {type:'create',name:'choice',declaration:{type:'combo',value:'absent',options:[{label:'A',value:'a'}]}},
  {type:'create',name:'color',declaration:{type:'color',value:'1 2 0'}},
  {type:'copy',name:'speed',newName:'speed'}, {type:'unknown',name:'speed'},
 ];
 for(const edit of edits){assert.throws(()=>doc.propertyDefinition(edit),undefined,JSON.stringify(edit));assert.deepEqual(doc.snapshot(),before);assert(!doc.canUndo);}
});
test('empty projects initialize metadata; malformed metadata remains explicit and unchanged',()=>{
 const value=initial();delete value.project.general;delete value.project.preset;
 const doc=new SceneDocument(value);create(doc,'flag',{type:'bool',value:true});assert.equal(doc.snapshot().project.general.properties.flag.value,true);doc.undo();assert.deepEqual(doc.snapshot(),value);
 for(const bad of [{general:null},{general:{properties:null}},{preset:null}]){
  const input={...initial(),project:{...initial().project,...bad}},broken=new SceneDocument(input);
  assert.throws(()=>create(broken,'flag',{type:'bool',value:true}),/metadata/);assert.deepEqual(broken.snapshot(),input);assert(!broken.canUndo);
 }
});
test('exact Unicode keys and ordinary-object special keys survive distinct transactions',()=>{
 const doc=new SceneDocument(initial());
 for(const name of ['é','e\u0301','constructor','prototype'])create(doc,name,{type:'textinput',value:name});
 const result=doc.snapshot().project.general.properties;
 for(const name of ['é','e\u0301','constructor','prototype'])assert.equal(result[name].value,name);
 doc.propertyDefinition({type:'update',name:'e\u0301',patch:{value:'changed'}});assert.equal(doc.snapshot().project.general.properties['é'].value,'é');
});
