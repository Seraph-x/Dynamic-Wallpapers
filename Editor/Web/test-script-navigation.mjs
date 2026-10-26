import assert from 'node:assert/strict';
import {openEditorHarness} from './browser-editor-harness.mjs';
import {migrationDocument,migrationResources} from './script-migration-fixture.mjs';
import {codeInput,inspectCodeEditor} from './test-code-editor-helpers.mjs';
const source='// 雪\r\nexport function update(value) {\r\n  return {x:1,y:0,z:0};\r\n}\r\n';
const original=structuredClone(migrationDocument);original.scene.objects[0].color.script=source;
const config={version:1,session:'navigation-test',generation:1,language:'en',document:{...original,scene:{...original.scene,objects:[]}}};
const h=await openEditorHarness(config),{page,command,resources,events,errors}=h;
try {
 for(const [name,bytes]of migrationResources())resources.set(name,bytes);
 await command({type:'thaw'});await command({type:'load',document:original});
 const capture=await command({type:'snapshot'}),link={documentIdentity:capture.documentIdentity,source,layerId:1,target:'color',path:['objects',0,'color','script'],line:3,registered:true};
 assert.equal(typeof capture.documentIdentity,'string','Capture must identify its actual SceneDocument');
 const reveal=async patch=>command({type:'reveal-script',link:{...link,...patch}});
 assert.equal((await reveal()).navigation.kind,'current');
 assert.equal(await page.locator('#script-panel').isVisible(),true);assert.equal(await page.locator('#script-target').inputValue(),'color');
 const state=await inspectCodeEditor(page);assert.equal(state.source,source.replaceAll('\r',''));assert.equal(state.selection.from,37);assert.equal(state.selection.to,60);
 assert.deepEqual((await command({type:'snapshot'})).document,original,'Navigation changed content');
 await page.locator('#properties-workspace').click();await page.locator('#field-alpha').fill('-1');
 assert.equal((await reveal()).navigation.reason,'pending');await page.locator('#script-captured-close').click();assert.equal(await page.locator('#field-alpha').inputValue(),'-1','Source navigation discarded a focused invalid property input');
 await page.locator('#field-alpha').fill('1');await page.locator('#field-alpha').press('Tab');await command({type:'snapshot'});
 await page.locator('#field-alpha').evaluate(input=>{globalThis.__navPropertyChanges=0;input.addEventListener('change',()=>globalThis.__navPropertyChanges++);});
 await page.locator('#field-alpha').fill('0.5');await reveal();await page.locator('#script-captured-dialog').waitFor({state:'visible'});assert.equal(await page.evaluate(()=>globalThis.__navPropertyChanges),0,'Read-only navigation dispatched a property commit');await page.locator('#script-captured-close').click();
 // Clicking outside a valid inspector field follows its ordinary blur/commit
 // behavior. The native navigation itself must leave that input focused.
 await page.locator('#field-alpha').fill('1');await page.locator('#script-workspace').click();assert.deepEqual((await command({type:'snapshot'})).document,original);
 await codeInput(page).fill('export function update( {');
 assert.equal((await reveal()).navigation.reason,'pending');await page.locator('#script-captured-dialog').waitFor({state:'visible'});
 const captured=page.locator('#script-captured-source .cm-content');assert.equal(await captured.getAttribute('contenteditable'),'false');assert.equal(await captured.getAttribute('tabindex'),'0');assert((await captured.innerText()).includes('return {x:1,y:0,z:0};'));
 await captured.focus();await page.keyboard.press('ControlOrMeta+a');await page.keyboard.press('ControlOrMeta+z');
 await page.locator('#script-captured-close').click();assert.equal(await codeInput(page).inputValue(),'export function update( {','Captured viewer overwrote invalid draft');
 await page.locator('#script-revert').click();await command({type:'snapshot'});
 const changed=structuredClone(original);changed.scene.objects[0].color.script='export function update(value){return value;}';await command({type:'load',document:changed});
 assert.equal((await reveal()).navigation.reason,'document');await page.locator('#script-captured-dialog').waitFor({state:'visible'});await page.locator('#script-captured-close').click();assert.deepEqual((await command({type:'snapshot'})).document,changed);
 for(const line of [null,999]){await reveal({line});assert((await page.locator('#script-captured-location').textContent()).trim());await page.locator('#script-captured-close').click();}
 await reveal({layerId:null,target:'general.zoom',registered:false,path:['general','zoom','script']});assert.equal(await page.locator('#script-captured-dialog').isVisible(),true);await page.locator('#script-captured-close').click();
 for(const language of ['en','zh-Hans','ja','fr','es']){config.language=language;config.document=original;const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await page.setViewportSize({width:850,height:540});for(const theme of ['light','dark']){await page.locator('#theme').selectOption(theme);await reveal();const layout=await page.locator('#script-captured-dialog').evaluate(dialog=>{const b=dialog.getBoundingClientRect();return {fits:b.left>=0&&b.top>=0&&b.right<=innerWidth&&b.bottom<=innerHeight,text:dialog.textContent,overflow:dialog.scrollWidth>dialog.clientWidth};});assert(layout.fits&&!layout.overflow&&!layout.text.includes('undefined'),language+'/'+theme);await page.locator('#script-captured-close').click();}}
 assert.equal(events.filter(e=>e.type==='resource'&&e.action==='stage').length,0);assert.deepEqual(errors,[]);
 console.log('Source navigation: current identity/CRLF exact line, invalid draft preserved, stale captures read-only, unavailable lines and five-language minimum layout passed');
}finally{await h.close();}
