import assert from 'node:assert/strict';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {openEditorHarness} from './browser-editor-harness.mjs';
import {migrationDocument,migrationResources,openScriptPlayback} from './script-migration-fixture.mjs';
import {readEditorPackage} from './package-archive.mjs';
import {codeInput,codeReadOnly,inspectCodeEditor} from './test-code-editor-helpers.mjs';

// Independent expected bytes: authoring output must never define its own oracle.
const authoredSource='// workspace authored — 雪\r\nexport function update(value){\r\n  return {x:1,y:0,z:0};\r\n}\r\n';
const original=structuredClone(migrationDocument);
original.scene.objects[0].color.script=original.scene.objects[0].color.script.replaceAll('\n','\r\n');
const expected=structuredClone(original);
expected.scene.objects[0].color.script=authoredSource;
const configuration={version:1,session:'script-workspace-test',generation:1,language:'en',document:{...original,scene:{...original.scene,objects:[]}}};
const h=await openEditorHarness(configuration),{page,resources,command,events,errors,artifactRoot,blobRoot}=h;
const sourceRequests=[];page.on('request',request=>{if(request.url().includes('migration-source-probe='))sourceRequests.push(request.url());});
const snapshot=async()=>(await command({type:'snapshot'})).document;
async function selectLayer(id){await page.locator(`#layers button[data-layer-id="${id}"]`).click();}
async function open(){await selectLayer(1);await page.locator('#script-workspace').click();await page.locator('#script-target').selectOption('color');}
const input=()=>codeInput(page);
async function check(){await page.locator('#script-check').click();}
async function apply(){await page.locator('#script-apply').click();}
async function revert(){await page.locator('#script-revert').click();}
async function quiet(){assert.deepEqual(await page.evaluate(()=>({migration:globalThis.__migrationProbe??null,unknown:globalThis.__migrationUnknownMetadataRan??null,authored:globalThis.__workspaceMustNotRun??null})),{migration:null,unknown:null,authored:null});}
try{
 assert.equal(await page.locator('#script-workspace').count(),1,'Missing real Script workspace entry');
 const blobs=(await readdir(blobRoot)).sort();for(const [name,bytes] of migrationResources())resources.set(name,bytes);
 await command({type:'thaw'});await command({type:'load',document:original});await open();
 assert.equal(await page.locator('#script-source').evaluate(e=>e.tagName),'DIV');assert.equal(await page.locator('#script-source textarea').count(),0);const codeState=await inspectCodeEditor(page);assert.equal(codeState.role,'textbox');assert(codeState.labelledBy?.split(' ').includes('script-source-label'));assert.equal(await page.locator('#script-target').evaluate(e=>e.tagName),'SELECT');
 assert.equal(await input().inputValue(),original.scene.objects[0].color.script.replaceAll('\r\n','\n'));assert.deepEqual(await snapshot(),original);
 // Check compiles real source, preserves pending text and cannot evaluate probes.
 const probe='globalThis.__workspaceMustNotRun=true;\nexport function update(value){return value;}';
 await input().fill(probe);await check();await quiet();await apply();const checked=await snapshot();assert.equal(checked.scene.objects[0].color.script,probe.replaceAll('\n','\r\n'));await quiet();await command({type:'undo'});assert.deepEqual(await snapshot(),original);
 await input().fill(probe);await revert();assert.deepEqual(await snapshot(),original);
 await input().fill('globalThis.__workspaceMustNotRun=true;');await check();assert.match(await page.locator('#script-diagnostics').textContent(),/entry|clock/i);await apply();assert.match(await page.locator('#script-diagnostics').textContent(),/entry|clock/i);await apply();assert.match(await page.locator('#script-diagnostics').textContent(),/entry|clock/i);await quiet();await command({type:'undo'});assert.deepEqual(await snapshot(),original);
 const invalid='export function update( {';
 await input().fill(invalid);await check();assert.equal(await input().getAttribute('aria-invalid'),'true');assert((await page.locator('#script-diagnostics').textContent()).trim());
 await assert.rejects(snapshot(),/script|syntax|unexpected|expected/i);await assert.rejects(command({type:'export-pkg',paths:[...resources.keys()]}),/script|syntax|unexpected|expected/i);await page.locator('#script-target').selectOption('alpha');
 assert.equal(await page.locator('#script-target').inputValue(),'color');assert.equal(await input().inputValue(),invalid);
 await selectLayer(3);assert.equal(await input().inputValue(),invalid);await page.locator('#properties-workspace').click();assert(await page.locator('#script-panel').isVisible());
 const frozen=await command({type:'freeze'});assert.deepEqual(frozen.document,original);assert(frozen.dirty);assert.equal(await page.evaluate(()=>document.body.inert),true);
 await assert.rejects(snapshot(),/script|syntax|unexpected|expected/i);await command({type:'thaw'});assert.equal(await input().inputValue(),invalid);await revert();assert.deepEqual(await snapshot(),original);
 await input().fill(authoredSource.replaceAll('\r\n','\n'));await command({type:'mark-saved',document:original});
 assert.equal(await input().inputValue(),authoredSource.replaceAll('\r\n','\n'),'mark-saved erased the pending source');assert.equal(await page.locator('#saved').getAttribute('data-dirty'),'true');await revert();
 // The visible code editor's local undo must not become a document-history operation.
 await input().focus();await page.keyboard.press('ControlOrMeta+End');await page.keyboard.type(' ');await page.keyboard.press('ControlOrMeta+z');
 assert.equal(await input().inputValue(),original.scene.objects[0].color.script.replaceAll('\r\n','\n'));assert.deepEqual(await snapshot(),original);
 await page.locator('#script-target').selectOption('alpha');await input().focus();await page.keyboard.type('x');await page.keyboard.press('ControlOrMeta+z');assert.equal(await input().inputValue(),'');
 const emptyUndone=await command({type:'freeze'});assert.deepEqual(emptyUndone.document,original);assert.equal(emptyUndone.dirty,false);await command({type:'thaw'});
 await apply();const emptyAlpha=await snapshot();assert.deepEqual(emptyAlpha.scene.objects[0].alpha,{value:1,script:''});await command({type:'undo'});assert.deepEqual(await snapshot(),original);await page.locator('#script-target').selectOption('color');
 // Imported CRLF is preserved without an input event; subsequent real input
 // keeps consistent CRLF. Mixed source intentionally follows LF after input.
 const crlf=structuredClone(original);crlf.scene.objects[0].color.script=authoredSource;
 await command({type:'load',document:crlf});assert.equal(await input().inputValue(),authoredSource.replaceAll('\r\n','\n'));assert.deepEqual(await snapshot(),crlf);
 await input().fill(authoredSource.replaceAll('\r\n','\n')+'// edited');await apply();
 const crlfEdited=structuredClone(crlf);crlfEdited.scene.objects[0].color.script=authoredSource+'// edited';assert.deepEqual(await snapshot(),crlfEdited);
 const mixed=structuredClone(original);mixed.scene.objects[0].color.script='// mixed\r\nexport function update(value){return value;}\n';
 await command({type:'load',document:mixed});assert.deepEqual(await snapshot(),mixed);await input().fill((await input().inputValue())+'// edited');await apply();
 assert.equal((await snapshot()).scene.objects[0].color.script,'// mixed\nexport function update(value){return value;}\n// edited');
 await command({type:'load',document:original});await input().fill('');await apply();assert.equal((await snapshot()).scene.objects[0].color.script,'');
 await page.locator('#script-remove').click();const removed=await snapshot();assert(!Object.hasOwn(removed.scene.objects[0].color,'script'));assert.equal(removed.scene.objects[0].color.value,'0 1 0');assert.deepEqual(removed.scene.objects[0].color.future,{keep:true});
 await command({type:'undo'});assert.equal((await snapshot()).scene.objects[0].color.script,'');await command({type:'undo'});assert.deepEqual(await snapshot(),original);
 const unsupported=structuredClone(original);unsupported.scene.objects[0].alpha={value:1,script:'export function update(v){return v;}',user:'bound'};
 await command({type:'load',document:unsupported});await page.locator('#script-target').selectOption('alpha');assert(await codeReadOnly(page));assert((await page.locator('#script-diagnostics').textContent()).trim());assert.deepEqual(await snapshot(),unsupported);
 await selectLayer(2);await page.locator('#script-target').selectOption('text');assert.equal(await input().inputValue(),original.scene.objects[2].text.script);const metadata=await page.locator('#script-target option').evaluateAll(options=>options.map(o=>o.value).filter(v=>v.startsWith('metadata:')));assert(metadata.length>0,'Unknown inline source must remain discoverable');
 await page.locator('#script-target').selectOption(metadata[0]);assert(await codeReadOnly(page));assert.equal(await input().inputValue(),original.scene.objects[2].future.script);assert.deepEqual(await snapshot(),unsupported);
 await selectLayer(3);await page.locator('#script-target').selectOption('effects[0].visible');assert.equal(await input().inputValue(),original.scene.objects[1].effects[0].visible.script);
 await command({type:'load',document:original});await open();await page.locator('#timeline-toggle').click();
 await page.locator('.timeline-key[data-property="origin"][data-channel="0"][data-frame="0"]').click();await page.locator('#timeline-key-value').fill('335');
 await input().fill(authoredSource.replaceAll('\r\n','\n'));await apply();
 assert.equal(await page.locator('#timeline-key-value').inputValue(),'335','Script Apply erased the independent Timeline draft');
 const combined=structuredClone(expected);combined.scene.objects[0].origin.animation.c0[0]={frame:0,value:335,front:{enabled:false},back:{enabled:false}};assert.deepEqual(await snapshot(),combined);
 await page.locator('#timeline-toggle').click();
 await command({type:'load',document:original});await open();await input().fill(authoredSource.replaceAll('\r\n','\n'));await apply();assert.deepEqual(await snapshot(),expected);
 await command({type:'load',document:original});await input().fill(authoredSource.replaceAll('\r\n','\n'));await selectLayer(3);
 const navigationExpected=expected;assert.deepEqual(await snapshot(),navigationExpected);
 await command({type:'undo'});assert.deepEqual(await snapshot(),original);await command({type:'redo'});assert.deepEqual(await snapshot(),navigationExpected);
 await command({type:'load',document:original});await open();await input().fill(authoredSource.replaceAll('\r\n','\n')+' ');await input().fill(authoredSource.replaceAll('\r\n','\n'));const pendingExport=await command({type:'export-pkg',paths:[...resources.keys()]});const pendingArchive=readEditorPackage(new Uint8Array(Buffer.from(pendingExport.pkg,'base64')));assert.deepEqual(JSON.parse(new TextDecoder().decode(pendingArchive.read('scene.json'))),expected.scene);assert.deepEqual(await snapshot(),expected);
 await command({type:'mark-saved',document:expected});assert.equal((await command({type:'freeze'})).dirty,false);await command({type:'thaw'});
 const saved=await snapshot();assert.deepEqual(saved,expected);const savedPath=path.join(artifactRoot,'script-workspace-saved.json');await writeFile(savedPath,JSON.stringify(saved));configuration.document=JSON.parse(await readFile(savedPath,'utf8'));const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await open();assert.deepEqual(await snapshot(),expected);
 const pkg=await command({type:'export-pkg',paths:[...resources.keys()]});const archive=readEditorPackage(new Uint8Array(Buffer.from(pkg.pkg,'base64')));assert.deepEqual(JSON.parse(new TextDecoder().decode(archive.read('scene.json'))),expected.scene);
 for(const form of ['Loose','Package']){const dir=path.join(artifactRoot,'ScriptWorkspace'+form);await mkdir(dir,{recursive:true});await writeFile(path.join(dir,'project.json'),JSON.stringify({...saved.project,file:form==='Loose'?'scene.json':'scene.pkg'}));if(form==='Package')await writeFile(path.join(dir,'scene.pkg'),Buffer.from(pkg.pkg,'base64'));else{await writeFile(path.join(dir,'scene.json'),JSON.stringify(saved.scene));for(const [name,bytes]of resources){const file=path.join(dir,name);await mkdir(path.dirname(file),{recursive:true});await writeFile(file,bytes);assert.deepEqual(await readFile(file),bytes);}}}
 for(const [name,bytes]of resources)assert.deepEqual(Buffer.from(archive.read(name)),bytes);
 await writeFile(path.join(artifactRoot,'script-workspace-source.json'),JSON.stringify(original));await writeFile(path.join(artifactRoot,'script-workspace-expected.json'),JSON.stringify(expected));
 const playback=await openScriptPlayback(page,expected,resources);try{
  await playback.waitForFunction(()=>globalThis.__migrationProbe?.general?.update>0);
  const shot=await playback.locator('#scene canvas').screenshot();
  const red=await playback.evaluate(async bytes=>{const image=await createImageBitmap(new Blob([new Uint8Array(bytes)],{type:'image/png'})),canvas=document.createElement('canvas');canvas.width=image.width;canvas.height=image.height;const context=canvas.getContext('2d');context.drawImage(image,0,0);image.close();const data=context.getImageData(0,0,canvas.width,canvas.height).data,halves=[0,0];for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){const i=(y*canvas.width+x)*4;if(data[i]>180&&data[i+1]<70&&data[i+2]<70)halves[x<canvas.width/2?0:1]++;}return halves;},[...shot]);
  assert(red.every(n=>n>100),'Authored script must render real red pixels in both model meshes');assert.equal(await playback.evaluate(()=>typeof globalThis.__dynamicWallpaperEditor),'undefined');
 }finally{await playback.close();}
 configuration.document=expected;await page.setViewportSize({width:850,height:540});
 for(const language of ['en','zh-Hans','ja','fr','es']){configuration.language=language;const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await open();await page.locator('#timeline-toggle').click();for(const theme of ['light','dark']){await page.locator('#theme').selectOption(theme);const layout=await page.evaluate(()=>{const panel=document.getElementById('script-panel'),source=document.getElementById('script-source'),r=source.getBoundingClientRect();return {rect:{left:r.left,right:r.right,top:r.top,bottom:r.bottom},viewport:{width:innerWidth,height:innerHeight},overflow:document.documentElement.scrollWidth>innerWidth||panel.scrollWidth>panel.clientWidth,inside:r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight,labels:[...panel.querySelectorAll('label')].every(l=>(l.control||l.id==='script-source-label'&&source.querySelector('.cm-content').getAttribute('aria-labelledby')?.split(' ').includes(l.id))&&l.textContent.trim()&&!l.textContent.includes('undefined')),buttons:[...panel.querySelectorAll('button')].every(b=>b.textContent.trim()&&!b.textContent.includes('undefined'))};});assert(layout.inside&&!layout.overflow&&layout.labels&&layout.buttons,language+'/'+theme+': '+JSON.stringify(layout));assert.deepEqual(await snapshot(),expected);await quiet();}}
 assert.deepEqual(sourceRequests,[],'Source executed network probes in authoring');assert.equal(events.filter(e=>e.type==='resource'&&e.action==='stage').length,0);assert.deepEqual((await readdir(blobRoot)).sort(),blobs);assert.deepEqual(errors,[]);
 console.log('Script workspace: real native forms/compiler, draft barriers, syntax recovery, local undo, CRLF/mixed bytes, bindings/metadata, history/save/reload, both exports, independent scripted pixels, five languages/themes/minimum layout and zero staging passed');
}finally{await h.close();}
