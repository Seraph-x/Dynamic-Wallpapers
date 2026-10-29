import assert from 'node:assert/strict';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {openEditorHarness} from './browser-editor-harness.mjs';
import {resourceRuntimeFixture} from './resource-script-fixtures.mjs';
import {codeInput,codeReadOnly} from './test-code-editor-helpers.mjs';
import {readEditorPackage} from './package-archive.mjs';

const configuration={version:1,session:'resource-workspace-test',generation:1,language:'en',document:{title:'Resources',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{objects:[]}}};
const h=await openEditorHarness(configuration),{page,resources,command,blobRoot,artifactRoot,errors}=h;
const snapshot=async()=>(await command({type:'snapshot'})).document;
async function writeResources(directory,files){await mkdir(directory,{recursive:true});for(const [name,bytes] of files){const output=path.join(directory,name);await mkdir(path.dirname(output),{recursive:true});await writeFile(output,bytes);}}
try{
 await command({type:'thaw'});
 for(const sink of ['effect','child-override','emitter-rate']){
  const fixture=resourceRuntimeFixture(sink);resources.clear();for(const [name,bytes] of fixture.files)resources.set(name,bytes);
  if(sink==='effect'){
   fixture.scene.objects.push({...structuredClone(fixture.scene.objects[0]),id:2,name:'Shared material consumer'});
   const raw=resources.get('materials/owned/effect.json').toString();resources.set('materials/owned/effect.json',Buffer.from(raw.slice(0,-1)+',"huge":9007199254740993,"future":1,"future":2}'));
  }
  resources.set('unknown-source.json',Buffer.from('{"future":{"script":"unconsumed source"}}'));
  const original={title:'Resources',entry:'scene.json',project:{type:'scene',file:'scene.json',future:{label:'雪😀',preserve:true}},scene:fixture.scene};
  await command({type:'load',document:original});await page.locator('#layers button[data-layer-id="1"]').click();await page.locator('#script-workspace').click();
  const logical=sink==='effect'?'materials/owned/effect.json':'particles/owned/root.json';
  await page.waitForFunction(logical=>[...document.querySelectorAll('#script-target option')].some(option=>option.value.startsWith('resource:')&&option.textContent.includes(logical)),logical,{timeout:5000});
  const anchor=sink==='effect'?['passes',0,'constantshadervalues','Value']:sink==='child-override'?['children',0,'instanceoverride','alpha']:['emitter',0,'rate'];
  const option='resource:'+JSON.stringify([logical,anchor]);
  await page.locator('#script-target').selectOption(option);await page.waitForFunction(()=>!document.getElementById('script-check').disabled);
  if(sink==='effect'){
   assert.match(await page.locator('#script-resource-scope').textContent(),/Affected consumers: 2/);
   const summary=page.locator('#script-resource-consumers summary');await summary.focus();await page.keyboard.press('Enter');
   await page.waitForFunction(()=>document.getElementById('script-resource-consumers').open);
   const consumers=await page.locator('#script-resource-consumers li').allTextContents();assert.equal(consumers.length,2);
   assert(consumers.some(label=>label.includes('Shared material consumer')));assert(consumers.every(label=>/objects\[\d\]\.effects\[0\]/.test(label)));
   await page.keyboard.press('Enter');assert.deepEqual(await snapshot(),original);
  }
  const input=codeInput(page),before=await input.inputValue();assert(before.includes('export function update'));assert.equal(await codeReadOnly(page),false);
  const invalid='export function update(){return (;}';await input.fill(invalid);await page.locator('#script-check').click();
  await assert.rejects(snapshot(),/syntax|unexpected|token/i);assert.equal(await input.inputValue(),invalid);
  await page.locator('#script-revert').click();await page.waitForFunction(()=>!document.getElementById('script-check').disabled);assert.equal(await input.inputValue(),before);
  if(sink==='effect'){
   const failStage=async route=>{const data=route.request().postDataJSON();if(data.type==='resource'&&data.action==='stage')await route.fulfill({status:503,body:'Resource stage failure'});else await route.continue();};
   await page.route('**/__editor/event',failStage);await input.fill('export function update(){return 1;}');await page.locator('#script-apply').click();
   await page.locator('#script-diagnostics').filter({hasText:/503/}).waitFor();assert.equal(await input.inputValue(),'export function update(){return 1;}');
   await page.unroute('**/__editor/event',failStage);await page.locator('#script-revert').click();assert.deepEqual(await snapshot(),original);
  }
  const result=sink==='effect'?'{x:0,y:0,z:1,w:1}':sink==='child-override'?'.4':'60';
  const edited="({}).constructor.constructor('return globalThis')().__resourceAuthoringMustNotRun=true;\nexport function update(value){return "+result+';}';
  await input.fill(edited);await page.locator('#script-check').click();assert.equal(await page.evaluate(()=>globalThis.__resourceAuthoringMustNotRun),undefined);
  await page.locator('#script-apply').click();const saved=await snapshot(),version=saved.resourceOverrides[logical];assert.match(version,/^[a-f0-9]{64}$/);
  const staged=await readFile(path.join(blobRoot,version)),originalBytes=resources.get(logical),parsed=JSON.parse(originalBytes);
  const old=sink==='effect'?parsed.passes[0].constantshadervalues.Value.script:sink==='child-override'?parsed.children[0].instanceoverride.alpha.script:parsed.emitter[0].rate.script;
  const expected=Buffer.from(originalBytes.toString().replace(JSON.stringify(old),JSON.stringify(edited)));assert.deepEqual(staged,expected);
  const expectedDigest=createHash('sha256').update(expected).digest('hex');assert.equal(version,expectedDigest);
  const expectedDocument={...structuredClone(original),resourceOverrides:{[logical]:expectedDigest}};assert.deepEqual(saved,expectedDocument,'Resource Apply changed content outside its single resource override');
  if(sink==='effect'){
   await page.locator('#project-title').fill('Unrelated title');await page.locator('#project-title').press('Tab');await snapshot();await command({type:'undo'});assert.deepEqual(await snapshot(),saved);
   await input.focus();await page.keyboard.press('ControlOrMeta+z');assert.equal(await input.inputValue(),before,'Unrelated document updates erased resource CodeMirror local history');
   await page.keyboard.press('ControlOrMeta+Shift+z');assert.equal(await input.inputValue(),edited);assert.deepEqual(await snapshot(),saved);
  }
  const captured=await command({type:'snapshot'}),pointer=[...anchor,'script'];
  const link={documentIdentity:captured.documentIdentity,layerId:1,target:'resource',path:pointer,source:edited,line:2,registered:true,resource:{kind:'resource',path:logical,sha256:version,pointer,text:edited}};
  assert.equal((await command({type:'reveal-script',link})).navigation.kind,'current');assert.equal(await page.locator('#script-target').inputValue(),option);
  await input.fill(invalid);assert.equal((await command({type:'reveal-script',link})).navigation.reason,'pending');
  assert.equal(await page.locator('#script-captured-source .cm-content').getAttribute('contenteditable'),'false');
  await page.locator('#script-captured-close').click();assert.equal(await input.inputValue(),invalid);await page.locator('#script-revert').click();await snapshot();
  assert.equal((await command({type:'reveal-script',link:{...link,resource:{...link.resource,sha256:'a'.repeat(64)}}})).navigation.reason,'source');await page.locator('#script-captured-close').click();
  await command({type:'undo'});assert.deepEqual(await snapshot(),original);await command({type:'redo'});assert.deepEqual(await snapshot(),saved);
  const exported=await command({type:'export-pkg',paths:[...resources.keys()]});const pkg=readEditorPackage(Buffer.from(exported.pkg,'base64'));
  for(const [name,bytes] of resources)if(!['scene.json','project.json'].includes(name))assert.deepEqual(Buffer.from(pkg.read(name)),name===logical?expected:bytes);
  const acceptance=path.join(artifactRoot,'ResourceScripts',sink),sourceFiles=new Map(resources),looseFiles=new Map(resources);
  sourceFiles.set('scene.json',Buffer.from(JSON.stringify(original.scene)));sourceFiles.set('project.json',Buffer.from(JSON.stringify(original.project)));
  looseFiles.set(logical,expected);looseFiles.set('scene.json',Buffer.from(JSON.stringify(saved.scene)));looseFiles.set('project.json',Buffer.from(JSON.stringify(saved.project)));
  await writeResources(path.join(acceptance,'Source'),sourceFiles);await writeResources(path.join(acceptance,'Loose'),looseFiles);
  await writeResources(path.join(acceptance,'Package'),new Map([['project.json',Buffer.from(JSON.stringify({...saved.project,file:'scene.pkg'}))],['scene.pkg',Buffer.from(exported.pkg,'base64')]]));
  await writeFile(path.join(acceptance,'source-document.json'),JSON.stringify(original));await writeFile(path.join(acceptance,'saved-document.json'),JSON.stringify(expectedDocument));
  await writeFile(path.join(acceptance,'target.json'),JSON.stringify({sink,path:logical,anchor,originalSource:old,editedSource:edited,expectedDigest:version}));
  await writeFile(path.join(acceptance,'expected-resource.bin'),expected);
  const packagedOriginals=new Map(resources);for(const name of pkg.paths)if(name!==logical&&!['scene.json','project.json'].includes(name)&&resources.has(name))assert.deepEqual(Buffer.from(pkg.read(name)),resources.get(name));
  await command({type:'mark-saved',document:saved});assert.equal((await command({type:'freeze'})).dirty,false);await command({type:'thaw'});
  configuration.document=saved;const ready=page.waitForRequest(request=>request.method()==='POST'&&request.url().endsWith('/__editor/event')&&request.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});
  await page.locator('#layers button[data-layer-id="1"]').click();await page.locator('#script-workspace').click();await page.locator('#script-target').selectOption(option);await page.waitForFunction(()=>!document.getElementById('script-check').disabled);
  assert.equal(await input.inputValue(),edited);assert.deepEqual(await snapshot(),saved);
  for(const [name,bytes] of packagedOriginals)assert.deepEqual(resources.get(name),bytes);
  if(sink==='effect'){
   const unsupported='resource:'+JSON.stringify(['unknown-source.json',['future']]);await page.locator('#script-target').selectOption(unsupported);await page.waitForFunction(()=>document.getElementById('script-target').value.includes('unknown-source.json')&&!document.getElementById('script-target').disabled);
   assert.equal(await codeReadOnly(page),true);assert.equal(await input.inputValue(),'unconsumed source');assert((await page.locator('#script-diagnostics').textContent()).trim());
   await page.locator('#script-target').selectOption(option);await snapshot();await page.setViewportSize({width:850,height:540});
   for(const language of ['en','zh-Hans','ja','fr','es']){
    configuration.language=language;const ready=page.waitForRequest(request=>request.method()==='POST'&&request.url().endsWith('/__editor/event')&&request.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await page.locator('#script-workspace').click();await page.locator('#script-target').selectOption(option);await snapshot();
    await page.locator('#timeline-toggle').click();
    const summary=page.locator('#script-resource-consumers summary');await summary.focus();await page.keyboard.press('Enter');
    assert.equal(await page.locator('#script-resource-consumers li').count(),2);assert(!(await summary.textContent()).includes('undefined'));
    assert.equal(await page.locator('#script-panel').evaluate(panel=>panel.scrollWidth>panel.clientWidth),false);await page.keyboard.press('Enter');
    for(const theme of ['light','dark']){await page.locator('#theme').selectOption(theme);const layout=await page.evaluate(()=>{const panel=document.getElementById('script-panel'),source=document.getElementById('script-source').getBoundingClientRect(),scope=document.getElementById('script-resource-scope');return {inside:source.left>=0&&source.right<=innerWidth&&source.top>=0&&source.bottom<=innerHeight,overflow:panel.scrollWidth>panel.clientWidth,scopeOverflow:scope.scrollWidth>scope.clientWidth,undefined:panel.textContent.includes('undefined')};});assert(layout.inside&&!layout.overflow&&!layout.scopeOverflow&&!layout.undefined,language+'/'+theme+': '+JSON.stringify(layout));}
   }
   await page.setViewportSize({width:1180,height:760});
  }
  // A new document whose original resources came from the real exported PKG
  // must remain authorable without relying on the previous override map.
  const packageInput={...saved,scene:JSON.parse(new TextDecoder().decode(pkg.read('scene.json')))};delete packageInput.resourceOverrides;
  resources.clear();for(const name of pkg.paths)resources.set(name,Buffer.from(pkg.read(name)));
  await command({type:'load',document:packageInput});await page.locator('#script-workspace').click();await page.locator('#script-target').selectOption(option);await snapshot();assert.equal(await input.inputValue(),edited);
  const packageSource=edited+'\n// package source';await input.fill(packageSource);await page.locator('#script-apply').click();const packageSaved=await snapshot();
  const packageVersion=packageSaved.resourceOverrides[logical];assert.deepEqual(await readFile(path.join(blobRoot,packageVersion)),Buffer.from(expected.toString().replace(JSON.stringify(edited),JSON.stringify(packageSource))));
  assert.deepEqual(Buffer.from(pkg.read(logical)),expected,'Editing extracted package bytes modified the original archive');
  await page.locator('#script-remove').click();const removed=await snapshot();assert.notEqual(removed.resourceOverrides[logical],packageVersion);
  assert.equal(await input.inputValue(),'');
  await page.locator('#script-template').selectOption('init');await page.locator('#script-use-template').click();
  const addedSource=await input.inputValue();assert.match(addedSource,/export function update/);
  await page.locator('#script-apply').click();const added=await snapshot();
  const addedBytes=await readFile(path.join(blobRoot,added.resourceOverrides[logical])),addedResource=JSON.parse(addedBytes);
  let addedWrapper=addedResource;for(const key of anchor)addedWrapper=addedWrapper[key];assert.equal(addedWrapper.script,addedSource);
  await command({type:'undo'});assert.deepEqual(await snapshot(),removed);await command({type:'redo'});assert.deepEqual(await snapshot(),added);
  assert.equal(await page.evaluate(()=>globalThis.__resourceAuthoringMustNotRun),undefined);
  console.log('PASS resource workspace',sink,'edit/check/revert/history/export/remove/template-add');
 }
 assert.deepEqual(errors,[]);
}finally{await h.close();}
