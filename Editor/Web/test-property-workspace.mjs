import assert from 'node:assert/strict';
import {mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {openEditorHarness} from './browser-editor-harness.mjs';
import {propertiesDocument} from './preview-properties-fixture.mjs';
import {readEditorPackage} from './package-archive.mjs';

const original=structuredClone(propertiesDocument);
const config={version:1,session:'property-definitions',generation:1,language:'en',document:original};
const h=await openEditorHarness(config),{page,command,errors,artifactRoot}=h;
const snapshot=async()=>(await command({type:'snapshot'})).document;
const apply=()=>page.locator('#user-property-apply').click();
const select=name=>page.locator('#user-property-list').selectOption(name);
async function create(name,type,value){
 await page.locator('#user-property-new').click();
 await page.locator('#user-property-key').fill(name);await page.locator('#user-property-type').selectOption(type);
 if(type==='bool')await page.locator('#user-property-value').setChecked(value);
 else await page.locator('#user-property-value').fill(value);
 await apply();
 assert.equal((await snapshot()).project.general.properties[name].value,type==='slider'?Number(value):value);
}
try{
 assert.equal(await page.locator('#project-workspace').count(),1,'Missing Project workspace');
 await command({type:'thaw'});
 await page.locator('#project-workspace').click();
 await create('authored-é','textinput','composed');await create('authored-e\u0301','textinput','decomposed');
 await create('authored','slider','2.5');
 await page.locator('#user-property-text').fill('Authored speed');await page.locator('#user-property-min').fill('0');await page.locator('#user-property-max').fill('5');await apply();
 const authored=await snapshot();assert.equal(authored.project.general.properties.authored.value,2.5);
 assert.equal(authored.project.general.properties['authored-é'].value,'composed');assert.equal(authored.project.general.properties['authored-e\u0301'].value,'decomposed');
 await page.locator('#user-property-value').fill('6');await apply();
 assert((await page.locator('#user-property-error').textContent()).trim());await assert.rejects(snapshot());
 const frozen=await command({type:'freeze'});assert(frozen.dirty);assert.deepEqual(frozen.document,authored);await command({type:'thaw'});
 await page.locator('#user-property-revert').click();assert.deepEqual(await snapshot(),authored);
 // Native capture flushes a valid draft even without a blur or Apply.
 await page.locator('#user-property-value').fill('4');const flushed=await snapshot();assert.equal(flushed.project.general.properties.authored.value,4);
 await command({type:'undo'});assert.deepEqual(await snapshot(),authored);await command({type:'redo'});
 await page.locator('#user-property-copy').click();await page.locator('#user-property-key').fill('copied');await apply();
 assert.equal((await snapshot()).project.general.properties.copied.value,4);
 await page.locator('#user-property-delete').click();assert(await page.locator('#user-property-delete-dialog').isVisible());
 await assert.rejects(snapshot(),/confirm|dialog|pending/i);await assert.rejects(command({type:'export-pkg',paths:[]}),/confirm|dialog|pending/i);
 const dialogFrozen=await command({type:'freeze'});assert(dialogFrozen.dirty);await command({type:'thaw'});await page.locator('#user-property-delete-cancel').click();
 await page.locator('#user-property-delete').click();
 const beforeDelete=await snapshot().catch(()=>undefined);assert.equal(beforeDelete,undefined);
 await page.evaluate(()=>{const confirm=document.getElementById('user-property-delete-confirm');confirm.click();confirm.click();});
 const afterDelete=await snapshot();assert(!Object.hasOwn(afterDelete.project.general.properties,'copied'));
 assert.equal(afterDelete.project.general.properties.enabled.value,true,'Rapid confirmation deleted another unconfirmed property');
 assert.equal(Object.keys(afterDelete.project.general.properties).length,Object.keys(flushed.project.general.properties).length,'Delete removed more than its confirmed definition');
 await command({type:'undo'});assert.equal((await snapshot()).project.general.properties.copied.value,4);
 await select('tint');await page.locator('#user-property-value').fill('1 0 0');await apply();
 await create('flag','bool',false);await select('caption');await page.locator('#user-property-value').fill('雪 & <text>');await apply();await create('paint','color','0.2 0.4 0.6');
 await page.locator('#user-property-new').click();await page.locator('#user-property-key').fill('options');await page.locator('#user-property-type').selectOption('combo');
 await page.locator('#user-property-option-label-0').fill('First');await page.locator('#user-property-option-value-0').fill('first');
 await page.locator('#user-property-value').selectOption('first');await apply();
 const saved=await snapshot();
 // Imported strings/unknown option fields must survive edits to other fields.
 const imported=structuredClone(saved);imported.project.general.properties.caption.value='line\r\nnext';imported.project.general.properties.mode.options[0].future={keep:['all']};
 await command({type:'load',document:imported});await select('caption');await page.locator('#user-property-text').fill('New label');await apply();
 assert.equal((await snapshot()).project.general.properties.caption.value,'line\r\nnext');
 await select('mode');await page.locator('#user-property-option-label-0').fill('Soft');await apply();assert.deepEqual((await snapshot()).project.general.properties.mode.options[0],{label:'Soft',value:'quiet',future:{keep:['all']}});
 await select('conditional');assert.equal(await page.locator('#user-property-form input').count(),0);assert(await page.locator('#user-property-copy').isDisabled());assert.match(await page.locator('#user-property-form').textContent(),/unsupported-condition/);
 const malformed=structuredClone(saved);malformed.project.general.properties=null;await command({type:'load',document:malformed});assert.match(await page.locator('#user-property-form').textContent(),/metadata/);await page.locator('#properties-workspace').click();assert(await page.locator('#property-panel').isVisible());assert.deepEqual(await snapshot(),malformed);
 await command({type:'load',document:saved});await page.locator('#project-workspace').click();
 await command({type:'mark-saved',document:saved});assert.equal((await command({type:'freeze'})).dirty,false);await command({type:'thaw'});
 config.document=saved;const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await page.locator('#project-workspace').click();assert.deepEqual(await snapshot(),saved);
 const pkg=await command({type:'export-pkg',paths:[]}),archive=readEditorPackage(new Uint8Array(Buffer.from(pkg.pkg,'base64')));
 assert.deepEqual(JSON.parse(new TextDecoder().decode(archive.read('scene.json'))),saved.scene);
 for(const kind of ['Loose','Package']){const dir=path.join(artifactRoot,'Definitions'+kind);await mkdir(dir,{recursive:true});await writeFile(path.join(dir,'project.json'),JSON.stringify({...saved.project,file:kind==='Loose'?'scene.json':'scene.pkg'}));await writeFile(path.join(dir,kind==='Loose'?'scene.json':'scene.pkg'),kind==='Loose'?JSON.stringify(saved.scene):Buffer.from(pkg.pkg,'base64'));}
 for(const language of ['en','zh-Hans','ja','fr','es']){
  config.language=language;const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await page.locator('#project-workspace').click();
  assert((await page.locator('#project-workspace').textContent()).trim());
  for(const theme of ['light','dark']){await page.locator('#theme').selectOption(theme);await page.setViewportSize({width:850,height:540});await page.locator('#user-property-value').scrollIntoViewIfNeeded();assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth&&document.getElementById('project-panel').scrollWidth<=document.getElementById('project-panel').clientWidth),true,'Localized property panel overflows');await page.screenshot({path:path.join(artifactRoot,`property-definitions-${language}-${theme}.png`)});}
  assert.deepEqual(await snapshot(),saved,'Appearance/language changed saved definitions');
 }
 assert.equal(await page.evaluate(()=>globalThis.__propertyProbe??null),null,'Authoring executed the scene callback');
 assert.deepEqual(errors,[]);console.log('Property workspace: real authoring, validation/freeze, exact Unicode, undo/reopen and loose/PKG exports passed');
}finally{await h.close();}
