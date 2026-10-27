import assert from 'node:assert/strict';
import {mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {openEditorHarness} from './browser-editor-harness.mjs';
import {bindingDocument} from './property-bindings-fixture.mjs';
import {readEditorPackage} from './package-archive.mjs';

const original=structuredClone(bindingDocument),configuration={version:1,session:'property-bindings',generation:1,language:'en',document:original};
const h=await openEditorHarness(configuration),{page,command,errors,artifactRoot}=h;
const snapshot=async()=>(await command({type:'snapshot'})).document;
const select=id=>page.locator(`#layers button[data-layer-id="${id}"]`).click();
async function open(field){await page.locator('#bind-'+field).click();await page.locator('#property-binding-dialog').waitFor({state:'visible'});}
async function bind(field,name,condition){await open(field);await page.locator('#property-binding-name').selectOption(name);if(condition!==undefined)await page.locator('#property-binding-condition').selectOption(condition);await page.locator('#property-binding-apply').click();await page.locator('#property-binding-dialog').waitFor({state:'hidden'});}
try{
 await command({type:'thaw'});await select(1);
 assert.equal(await page.locator('#bind-color').count(),1,'Missing inspector binding control');
 await open('color');assert(await page.locator('#property-binding-current').textContent());
 await assert.rejects(snapshot(),/binding.*dialog|confirm/i);await assert.rejects(command({type:'export-pkg',paths:[]}),/binding.*dialog|confirm/i);
 const frozen=await command({type:'freeze'});assert(frozen.dirty);assert.deepEqual(frozen.document,original);await command({type:'thaw'});await page.locator('#property-binding-cancel').click();assert.deepEqual(await snapshot(),original);
 await bind('color','tint');await bind('alpha','opacity');await bind('visible','enabled');
 await select(2);await bind('visible','mode','night');await select(3);await bind('text','caption');await bind('pointsize','fontSize');
 const authored=await snapshot();
 assert.deepEqual(authored.scene.objects[0].color,{value:'0 1 0',user:'tint'});assert.deepEqual(authored.scene.objects[1].visible,{value:true,user:{name:'mode',condition:'night'}});
 assert.deepEqual(authored.scene.objects[2].text,{value:'Original\r\n雪',user:'caption'});assert.deepEqual(authored.scene.objects[2].pointsize,{value:24,user:'fontSize'});assert.deepEqual(authored.project,original.project);
 for(let i=0;i<6;i++)await command({type:'undo'});assert.deepEqual(await snapshot(),original);for(let i=0;i<6;i++)await command({type:'redo'});assert.deepEqual(await snapshot(),authored);
 await select(4);await open('color');assert.match(await page.locator('#property-binding-warning').textContent(),/script/i);await page.locator('#property-binding-name').selectOption('tint');
 await page.evaluate(()=>{const button=document.getElementById('property-binding-apply');button.click();button.click();});await page.locator('#property-binding-dialog').waitFor({state:'hidden'});
 const replacement=await snapshot();assert.deepEqual(replacement.scene.objects[3].color,{value:'0 1 0',user:'tint',scriptproperties:{future:true},future:{keep:'🌙'}});await command({type:'undo'});assert.deepEqual(await snapshot(),authored);
 await select(3);await open('text');await page.locator('#property-binding-remove').click();await page.locator('#property-binding-dialog').waitFor({state:'hidden'});assert.equal((await snapshot()).scene.objects[2].text,'Original\r\n雪');await command({type:'undo'});assert.deepEqual(await snapshot(),authored);
 await open('text');await page.locator('#property-binding-name').selectOption('e\u0301');await page.locator('#property-binding-apply').click();await page.locator('#property-binding-dialog').waitFor({state:'hidden'});assert.equal((await snapshot()).scene.objects[2].text.user,'e\u0301');await command({type:'undo'});
 await command({type:'mark-saved',document:authored});assert.equal((await command({type:'freeze'})).dirty,false);await command({type:'thaw'});
 configuration.document=authored;const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});assert.deepEqual(await snapshot(),authored);
 const pkg=await command({type:'export-pkg',paths:[]}),archive=readEditorPackage(new Uint8Array(Buffer.from(pkg.pkg,'base64')));assert.deepEqual(JSON.parse(new TextDecoder().decode(archive.read('scene.json'))),authored.scene);
 for(const kind of ['Loose','Package']){const directory=path.join(artifactRoot,'Bindings'+kind);await mkdir(directory,{recursive:true});await writeFile(path.join(directory,'project.json'),JSON.stringify({...authored.project,file:kind==='Loose'?'scene.json':'scene.pkg'}));await writeFile(path.join(directory,kind==='Loose'?'scene.json':'scene.pkg'),kind==='Loose'?JSON.stringify(authored.scene):Buffer.from(pkg.pkg,'base64'));}
 await writeFile(path.join(artifactRoot,'bindings-source.json'),JSON.stringify(original));await writeFile(path.join(artifactRoot,'bindings-expected.json'),JSON.stringify(authored));
 for(const language of ['en','zh-Hans','ja','fr','es']){
  configuration.language=language;const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await select(1);await page.setViewportSize({width:850,height:540});await open('color');
  for(const theme of ['light','dark']){await page.evaluate(value=>{const select=document.getElementById('theme');select.value=value;select.dispatchEvent(new Event('change'));},theme);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth&&document.getElementById('property-binding-dialog').scrollWidth<=document.getElementById('property-binding-dialog').clientWidth),true);await page.screenshot({path:path.join(artifactRoot,`binding-${language}-${theme}.png`)});}
  await page.keyboard.press('Escape');assert.deepEqual(await snapshot(),authored);
 }
 assert.deepEqual(errors,[]);console.log('Binding workbench: actual forms, modal barriers, replacement/removal, exact Unicode, atomic history, saved reopen, loose/PKG exports and five-language/theme minimum layout passed');
}finally{await h.close();}
