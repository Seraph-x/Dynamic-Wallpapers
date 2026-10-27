import test from 'node:test';
import assert from 'node:assert/strict';
import { SceneDocument } from './document.mjs';
import * as bindings from './property-bindings.mjs';
const {inspectPropertyBinding}=bindings;

const initial=()=>({title:'Bindings',entry:'scene.json',project:{type:'scene',general:{properties:{
 flag:{type:'bool',value:false},amount:{type:'slider',value:0.5,min:0,max:1},size:{type:'slider',value:28},tint:{type:'color',value:'1 0 0'},caption:{type:'textinput',value:'雪'},mode:{type:'combo',value:'day',options:[{label:'Day',value:'day'},{label:'Night',value:'night'}]},
 numeric:{type:'combo',value:'01',options:[{label:'One',value:'01'},{label:'Two',value:'2'}]},conditional:{type:'bool',value:true,condition:'flag'},'é':{type:'textinput',value:'composed'},'e\u0301':{type:'textinput',value:'decomposed'},
}}},scene:{future:{keep:true},objects:[{id:1,name:'Text',text:'Original\r\n雪',alpha:0.8,color:'0 1 0',pointsize:32},{id:2,name:'Solid',solid:true,size:'80 80',origin:'100 100 0'}]}});
const bind=(doc,field,name,extra={})=>doc.bindProperty({type:'bind',layerId:1,field,name,...extra});

test('direct bindings retain exact bases, metadata and one-step history through save/reopen',()=>{
 const input=initial(),doc=new SceneDocument(input);
 for(const [field,name]of [['visible','flag'],['alpha','amount'],['color','tint'],['text','caption'],['pointsize','size']])bind(doc,field,name);
 const result=doc.snapshot();
 assert.deepEqual(result.scene.objects[0].visible,{value:true,user:'flag'});
 for(const [field,name]of [['alpha','amount'],['color','tint'],['text','caption'],['pointsize','size']])assert.deepEqual(result.scene.objects[0][field],{value:input.scene.objects[0][field],user:name});
 assert.deepEqual(result.project,input.project);assert.deepEqual(result.scene.future,input.scene.future);assert.deepEqual(input,initial());
 for(let i=0;i<5;i++)doc.undo();assert.deepEqual(doc.snapshot(),input);
 for(let i=0;i<5;i++)doc.redo();assert.deepEqual(doc.snapshot(),result);doc.markSaved();assert(!doc.dirty);
 assert.deepEqual(new SceneDocument(JSON.parse(JSON.stringify(result))).snapshot(),result);
});
test('combo visibility uses native condition form and text choice retains string semantics',()=>{
 const doc=new SceneDocument(initial());bind(doc,'visible','mode',{condition:'night'});
 assert.deepEqual(doc.snapshot().scene.objects[0].visible,{value:true,user:{name:'mode',condition:'night'}});
 bind(doc,'text','mode');assert.equal(doc.snapshot().scene.objects[0].text.user,'mode');
 doc.undo();doc.undo();bind(doc,'visible','numeric',{condition:'01'});assert.equal(doc.snapshot().scene.objects[0].visible.user.condition,'01');
});
test('replace is explicit and removal preserves base, wrapper metadata and other controls',()=>{
 const input=initial();input.scene.objects[0].alpha={value:0.8,script:'export function update(v){return v;}',scriptproperties:{keep:true},animation:{unknown:[1,2]},future:{keep:'🌙'}};
 const doc=new SceneDocument(input);assert.throws(()=>bind(doc,'alpha','amount'),/replace|Replace/);assert(!doc.canUndo);
 bind(doc,'alpha','amount',{replace:true});assert.deepEqual(doc.snapshot().scene.objects[0].alpha,{value:0.8,user:'amount',scriptproperties:{keep:true},future:{keep:'🌙'}});
 doc.bindProperty({type:'remove',layerId:1,field:'alpha'});assert.deepEqual(doc.snapshot().scene.objects[0].alpha,{value:0.8,scriptproperties:{keep:true},future:{keep:'🌙'}});
 doc.undo();doc.undo();assert.deepEqual(doc.snapshot(),input);
 const compound=initial();compound.scene.objects[0].alpha={value:0.8,user:'amount',script:'exact\r\nsource',animation:{keep:true}};
 const remove=new SceneDocument(compound);remove.bindProperty({type:'remove',layerId:1,field:'alpha'});assert.deepEqual(remove.snapshot().scene.objects[0].alpha,{value:0.8,script:'exact\r\nsource',animation:{keep:true}});
});
test('invalid targets and incompatible defaults reject atomically without invented fallback',()=>{
 const doc=new SceneDocument(initial()),before=doc.snapshot();
 for(const edit of [
  ...[['visible','amount'],['color','amount'],['alpha','tint'],['text','flag'],['text','numeric'],['visible','mode'],['visible','mode','absent'],['visible','flag','night'],['text','conditional'],['alpha','missing'],['origin','tint']].map(([field,name,condition])=>({type:'bind',layerId:1,field,name,...(condition===undefined?{}:{condition})})),
  {type:'bind',layerId:2,field:'text',name:'caption'},{type:'bind',layerId:99,field:'alpha',name:'amount'},{type:'remove',layerId:1,field:'alpha'},
 ]){assert.throws(()=>doc.bindProperty(edit),undefined,JSON.stringify(edit));assert.deepEqual(doc.snapshot(),before);assert(!doc.canUndo);}
 for(const [field,name,value]of [['alpha','amount',2],['pointsize','size',0],['color','tint','0 2 0']]){
  const input=initial();input.project.general.properties[name].value=value;const invalid=new SceneDocument(input);assert.throws(()=>bind(invalid,field,name));assert.deepEqual(invalid.snapshot(),input);
 }
 const numericBase=initial();numericBase.scene.objects[0].text='123';const numericDoc=new SceneDocument(numericBase);assert.throws(()=>bind(numericDoc,'text','caption'),/shape|numeric|text/);assert.equal(numericDoc.snapshot().scene.objects[0].text,'123');
 const missingBase=initial();missingBase.scene.objects[0].alpha={user:'amount'};assert.throws(()=>bind(new SceneDocument(missingBase),'alpha','amount',{replace:true}),/base/);
 const duplicated=initial();duplicated.scene.objects.push({...duplicated.scene.objects[0]});assert.throws(()=>bind(new SceneDocument(duplicated),'alpha','amount'),/Ambiguous/);
});
test('exact Unicode keys stay distinct, same bindings are no-ops, removal restores literal base',()=>{
 const doc=new SceneDocument(initial());bind(doc,'text','é');bind(doc,'text','é',{replace:true});doc.undo();assert.deepEqual(doc.snapshot(),initial());assert(!doc.canUndo);
 bind(doc,'text','e\u0301');assert.equal(doc.snapshot().scene.objects[0].text.user,'e\u0301');
 doc.bindProperty({type:'remove',layerId:1,field:'text'});assert.equal(doc.snapshot().scene.objects[0].text,initial().scene.objects[0].text);
});
test('inspection exposes malformed bases without changing or hiding original content',()=>{
 const input=initial();input.scene.objects[0].alpha={user:'amount',future:{keep:true}};
 const invalid=inspectPropertyBinding(input,{layerId:1,field:'alpha'});assert.match(invalid.reason,/base/);assert.deepEqual(invalid.raw,input.scene.objects[0].alpha);
});
test('inspection exposes unresolved or unsupported current condition descriptors',()=>{
 for(const [field,user]of [['visible',{name:'mode',condition:'missing'}],['visible','mode'],['text',{name:'caption',condition:'x'}]]){
  const input=initial();input.scene.objects[0][field]={value:field==='text'?'original':true,user};
  const state=inspectPropertyBinding(input,{layerId:1,field});assert.match(state.currentError,/condition|descriptor/i);assert(state.hasUser);assert(!state.reason);
 }
});
test('the renderer cannot resolve an empty property identifier',()=>{
 const doc=initial();doc.project.general.properties['']={type:'bool',value:false};const noName=new SceneDocument(doc);assert.throws(()=>bind(noName,'visible',''),/identifier|name/i);assert(!noName.canUndo);
});
test('an absent point size uses the pinned 24-point default and survives exact undo',()=>{
 const input=initial();delete input.scene.objects[0].pointsize;const doc=new SceneDocument(input);bind(doc,'pointsize','size');assert.deepEqual(doc.snapshot().scene.objects[0].pointsize,{value:24,user:'size'});doc.undo();assert.deepEqual(doc.snapshot(),input);
});
test('captured field, declaration and document identity must still match before confirmation',()=>{
 const capture=doc=>({document:doc,identity:'first',selection:{layerId:1,field:'alpha'},state:inspectPropertyBinding(doc.snapshot(),{layerId:1,field:'alpha'})});
 const context=document=>({document,identity:'first',name:'amount'});
 assert.equal(typeof bindings.assertPropertyBindingCapture,'function');
 const doc=new SceneDocument(initial()),saved=capture(doc);
 bindings.assertPropertyBindingCapture(saved,context(doc));
 doc.patch(1,{name:'Unrelated'});bindings.assertPropertyBindingCapture(saved,context(doc));
 doc.patch(1,{alpha:0.4});assert.throws(()=>bindings.assertPropertyBindingCapture(saved,context(doc)),/changed/i);
 const definitions=new SceneDocument(initial()),declared=capture(definitions);
 definitions.propertyDefinition({type:'update',name:'flag',patch:{value:true}});bindings.assertPropertyBindingCapture(declared,context(definitions));
 definitions.propertyDefinition({type:'update',name:'amount',patch:{value:0.7}});assert.throws(()=>bindings.assertPropertyBindingCapture(declared,context(definitions)),/changed/i);
 assert.throws(()=>bindings.assertPropertyBindingCapture(saved,{...context(doc),identity:'next'}),/changed/i);
 assert.throws(()=>bindings.assertPropertyBindingCapture(saved,context(new SceneDocument(initial()))),/changed/i);
 const removed=new SceneDocument(initial()),target=capture(removed);removed.remove(1);assert.throws(()=>bindings.assertPropertyBindingCapture(target,context(removed)),/changed/i);
});
