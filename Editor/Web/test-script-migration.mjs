import assert from 'node:assert/strict';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {openEditorHarness} from './browser-editor-harness.mjs';
import {migrationAnchors,migrationDocument,migrationResources,openScriptPlayback} from './script-migration-fixture.mjs';
import {pixels} from './test-model.mjs';
import {readEditorPackage} from './package-archive.mjs';

const source=structuredClone(migrationDocument),configuration={version:1,session:'script-migration-test',generation:1,language:'en',document:{...source,scene:{...source.scene,objects:[]}}};
const h=await openEditorHarness(configuration),{page,resources,command,events,errors,artifactRoot,blobRoot}=h;
const sourceRequests=[];page.on('request',request=>{if(request.url().includes('migration-source-probe='))sourceRequests.push(request.url());});
const snapshot=async()=>(await command({type:'snapshot'})).document;
async function noExecution(){assert.deepEqual(await page.evaluate(()=>({probe:globalThis.__migrationProbe??null,unknown:globalThis.__migrationUnknownMetadataRan??null})),{probe:null,unknown:null},'Imported source executed inside authoring origin');}
try{
 const blobs=(await readdir(blobRoot)).sort();for(const [name,bytes] of migrationResources())resources.set(name,bytes);
 // An affirmative control uses the identical document/resource bytes. Unsupported
 // anchors cannot satisfy this assertion merely by remaining quiet in edit mode.
 const playback=await openScriptPlayback(page,source,resources);
 try{
  await playback.waitForFunction(anchors=>anchors.every(name=>{const p=globalThis.__migrationProbe?.[name];return p?.top>0&&p.init>0&&p.update>0&&p.network===200;}),migrationAnchors);
  assert.equal(new URL(playback.url()).origin==='http://migration-preview.test',true);
  assert.deepEqual(await playback.evaluate(()=>({unknown:globalThis.__migrationUnknownMetadataRan??null,authoring:typeof globalThis.__dynamicWallpaperEditor,errors:globalThis.__playbackErrors})),{unknown:null,authoring:'undefined',errors:[]});
  console.log('Migration positive control:',await playback.evaluate(()=>globalThis.__migrationProbe));
 }finally{await playback.close();}
 await command({type:'thaw'});await command({type:'load',document:source});await noExecution();
 await page.locator('#playback').click();await command({type:'seek',time:0});const first=await pixels(page);
 await command({type:'seek',time:.5});const moved=await pixels(page);
 assert(first.halves.every(p=>p.n>100)&&moved.halves.every(p=>p.n>100),'Actual model pixels missing');
 assert(moved.halves[0].x-first.halves[0].x>5,'Non-script property curve stopped animating');
 assert(first.halves[1].y-moved.halves[1].y>5,'Non-script skeletal animation stopped animating');
 await page.locator('#project-title').fill('Migration edited');const edited=await snapshot();assert.equal(edited.title,'Migration edited');
 await command({type:'undo'});assert.deepEqual(await snapshot(),source);await command({type:'redo'});assert.deepEqual(await snapshot(),edited);await noExecution();
 await command({type:'load',document:source});await command({type:'mark-saved',document:source});assert.deepEqual(await snapshot(),source);
 const pkg=await command({type:'export-pkg',paths:[...resources.keys()]});
 for(const form of ['Loose','Package']){
  const dir=path.join(artifactRoot,'Migration'+form);await mkdir(dir,{recursive:true});await writeFile(path.join(dir,'project.json'),JSON.stringify({...source.project,file:form==='Loose'?'scene.json':'scene.pkg'}));
  if(form==='Package')await writeFile(path.join(dir,'scene.pkg'),Buffer.from(pkg.pkg,'base64'));
  else{await writeFile(path.join(dir,'scene.json'),JSON.stringify(source.scene));for(const [name,bytes] of resources){const file=path.join(dir,name);await mkdir(path.dirname(file),{recursive:true});await writeFile(file,bytes);assert.deepEqual(await readFile(file),bytes);}}
 }
 await writeFile(path.join(artifactRoot,'script-migration-document.json'),JSON.stringify(source));await writeFile(path.join(artifactRoot,'script-migration-resources.json'),JSON.stringify([...resources.keys()]));
 const archive=readEditorPackage(new Uint8Array(Buffer.from(pkg.pkg,'base64')));assert.deepEqual(JSON.parse(new TextDecoder().decode(archive.read('scene.json'))),source.scene);for(const [name,bytes] of resources)assert.deepEqual(Buffer.from(archive.read(name)),bytes);
 await noExecution();assert.equal(events.filter(e=>e.type==='resource'&&e.action==='stage').length,0);assert.deepEqual((await readdir(blobRoot)).sort(),blobs);
 const before=await snapshot();const count=events.filter(e=>e.type==='preview').length;
 await page.locator('#run-preview').click();await snapshot();assert.deepEqual(events.filter(e=>e.type==='preview').slice(count),[{type:'preview',session:configuration.session,generation:configuration.generation}]);assert.deepEqual(await snapshot(),before);
 await page.locator('#run-preview').focus();await page.keyboard.press('Enter');await snapshot();await page.locator('#run-preview').focus();await page.keyboard.press('Space');await snapshot();assert.equal(events.filter(e=>e.type==='preview').length,count+3);
 await command({type:'freeze'});assert.equal(await page.evaluate(()=>document.body.inert),true);await assert.rejects(page.locator('#run-preview').click({timeout:300}),/Timeout/);assert.equal(events.filter(e=>e.type==='preview').length,count+3);await command({type:'thaw'});
 await page.route('**/__editor/event',async route=>{if(route.request().postDataJSON().type==='preview')await route.fulfill({status:503,body:'intentional preview transport failure'});else await route.continue();});await page.locator('#run-preview').click();await page.locator('#diagnostics').filter({hasText:/503/}).waitFor();await page.unroute('**/__editor/event');assert.deepEqual(await snapshot(),before);
 configuration.document=source;await page.setViewportSize({width:850,height:540});
 for(const language of ['en','zh-Hans','ja','fr','es']){
  configuration.language=language;const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await page.locator('#timeline-toggle').click();
  for(const theme of ['light','dark']){await page.locator('#theme').selectOption(theme);const layout=await page.evaluate(()=>{const button=document.getElementById('run-preview'),note=document.getElementById('script-mode-note'),b=button.getBoundingClientRect(),n=note.getBoundingClientRect();return {tag:button.tagName,text:button.textContent.trim(),description:button.getAttribute('aria-describedby'),note:note.textContent.trim(),inside:b.left>=0&&b.right<=innerWidth&&b.top>=0&&b.bottom<=innerHeight&&n.left>=0&&n.right<=innerWidth&&n.top>=0&&n.bottom<=innerHeight,overflow:document.documentElement.scrollWidth>innerWidth};});assert.equal(layout.tag,'BUTTON');assert(layout.text&&layout.note&&!layout.note.includes('undefined'));assert(layout.description?.split(' ').includes('script-mode-note'));assert(layout.inside&&!layout.overflow,language+'/'+theme+' Run layout');assert.deepEqual(await snapshot(),source);await noExecution();}
 }
 assert.deepEqual(sourceRequests,[],'Imported source sent network probes from authoring origin');assert.deepEqual(errors,[]);console.log('Script migration: exact positive anchors, scripts skipped on real workbench mounts/history/seek/save/export, live curves/MDL, byte-identical loose/PKG, fixed Run transport, native button keys, five-language minimum layout and zero staging passed');
}finally{await h.close();}
