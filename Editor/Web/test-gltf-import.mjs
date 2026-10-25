import assert from 'node:assert/strict';
import { readFile,writeFile,mkdir } from 'node:fs/promises';
import path from 'node:path';
import { openEditorHarness } from './browser-editor-harness.mjs';
import { rigGltf,changeGltf,glbSource } from './gltf-fixtures.mjs';
import { inspectModel } from './model.mjs';
import { encodePng } from './vendor/gltf-png.mjs';
import { inflateSync } from 'node:zlib';
import { readEditorPackage } from './package-archive.mjs';
const original={title:'glTF authoring',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{general:{orthogonalprojection:{width:640,height:360},clearcolor:'0.05 0.05 0.08',clearenabled:true,cameraparallax:false},objects:[]}};
const configuration={version:1,session:'gltf-import-test',generation:1,language:'en',document:original};
const h=await openEditorHarness(configuration),{page,command,errors,blobRoot,artifactRoot}=h;
const commandSource=source=>({entry:source.entry,files:source.files.map(file=>({path:file.path,data:Buffer.from(file.bytes).toString('base64')}))});
const modelSource=()=>changeGltf(rigGltf({duration:.37}),(j,s)=>{j.buffers[0].uri='rig.pkg';s.files[1].path='rig.pkg';j.images=[{uri:'original.png'}];s.files.push({path:'original.png',bytes:encodePng(2,2,Uint8Array.of(255,0,0,0,17,99,211,1,0,255,0,255,0,0,255,128))});});
async function open(source=modelSource()){await command({type:'import-model',source:commandSource(source)});await page.locator('#gltf-dialog').waitFor();}
try{
 const colored=Uint8Array.of(255,0,0,0,17,99,211,1,0,255,0,255,0,0,255,128),png=encodePng(2,2,colored),textured=changeGltf(rigGltf(),(j,s)=>{j.images=[{uri:'color.png'}];j.textures=[{source:0}];j.materials[0].pbrMetallicRoughness={baseColorFactor:[1,1,1,1],baseColorTexture:{index:0}};s.files.push({path:'color.png',bytes:png});});
 const textureBytes=Uint8Array.from(await page.evaluate(async source=>{const api=await import('./model-api.mjs'),parsed=api.parseGltfSource({entry:source.entry,files:source.files.map(f=>({path:f.path,bytes:Uint8Array.from(atob(f.data),c=>c.charCodeAt(0))}))}),candidate=await api.prepareGltfCandidate(api.buildGltfModel(parsed,{identifier:'pixels'}));return [...candidate.files.find(f=>f.path==='materials/editor/pixels_0.png').data];},commandSource(textured)));
 const chunks=[];for(let at=8;at<textureBytes.length;){const size=new DataView(textureBytes.buffer).getUint32(at);if(new TextDecoder().decode(textureBytes.subarray(at+4,at+8))==='IDAT')chunks.push(textureBytes.subarray(at+8,at+8+size));at+=size+12;}
 const decoded=inflateSync(Buffer.concat(chunks)),expected=colored.slice();for(let i=3;i<expected.length;i+=4)expected[i]=255;assert.deepEqual([...decoded],[0,...expected.slice(0,8),0,...expected.slice(8)],'OPAQUE conversion must retain transparent/low-alpha RGB and image orientation');
 await command({type:'thaw'});
 await open(textured);assert.equal(await page.locator('#gltf-error').textContent(),'');
 const previewPixels=await page.locator('#gltf-preview canvas').screenshot();
 const redPixels=await page.evaluate(async bytes=>{const image=await createImageBitmap(new Blob([Uint8Array.from(bytes)],{type:'image/png'}));try{const canvas=document.createElement('canvas');canvas.width=image.width;canvas.height=image.height;const ctx=canvas.getContext('2d');ctx.drawImage(image,0,0);const rgba=ctx.getImageData(0,0,canvas.width,canvas.height).data;let count=0;for(let i=0;i<rgba.length;i+=4)if(rgba[i]>180&&rgba[i+1]<70&&rgba[i+2]<70)count++;return count;}finally{image.close();}},[...previewPixels]);
 assert(redPixels>50,'Actual candidate renderer must display red RGB whose original texture alpha was zero');await page.locator('#gltf-cancel').click();
 const binarySource=rigGltf(),binaryJSON=JSON.parse(new TextDecoder().decode(binarySource.files[0].bytes));delete binaryJSON.buffers[0].uri;await open(glbSource(binaryJSON,binarySource.files[1].bytes));assert.equal(await page.locator('#gltf-error').textContent(),'');await page.locator('#gltf-cancel').click();
 for(const change of [j=>j.scenes=[null],j=>j.scene=99]){await assert.rejects(command({type:'import-model',source:commandSource(changeGltf(rigGltf(),change))}),/scene/);assert.deepEqual((await command({type:'snapshot'})).document,original);}
 await open();assert.equal(await page.locator('#gltf-error').textContent(),'');assert.equal(await page.locator('#gltf-stats').textContent(),'Meshes / Bones / Clips: 2 / 4 / 1');
 await assert.rejects(command({type:'snapshot'}),/Finish or cancel model import/);await page.locator('#gltf-cancel').click();await page.waitForFunction(()=>!document.querySelector('#gltf-dialog').open);assert.deepEqual((await command({type:'snapshot'})).document,original);
 await open(changeGltf(rigGltf(),j=>delete j.materials[0].extensions));assert(await page.locator('#gltf-consent').isVisible());assert.equal(await page.locator('#gltf-consent').isChecked(),false);await page.locator('#gltf-confirm').click();assert(await page.locator('#gltf-dialog').isVisible());await page.locator('#gltf-cancel').click();
 await open(changeGltf(rigGltf(),j=>j.materials[0].doubleSided=false));assert(await page.locator('#gltf-two-sided-note').isVisible());assert.equal(await page.locator('#gltf-consent').isChecked(),false);await page.locator('#gltf-confirm').click();assert(await page.locator('#gltf-dialog').isVisible());await page.locator('#gltf-cancel').click();
 await open();await page.locator('#gltf-mode').selectOption('single');await page.locator('#gltf-update').click();await page.waitForFunction(()=>document.querySelector('#gltf-error').textContent==='');await page.locator('#gltf-confirm').click();await page.waitForFunction(()=>!document.querySelector('#gltf-dialog').open);
 const snapshot=(await command({type:'snapshot'})).document;assert.equal(snapshot.scene.objects.length,1);const layer=snapshot.scene.objects[0],versions=snapshot.resourceOverrides;assert(layer.model.endsWith('.mdl'));const bytes=await readFile(path.join(blobRoot,versions[layer.model])),mdl=inspectModel(bytes);assert.equal(mdl.bones.length,4);assert.equal(mdl.meshes.length,2);assert.equal(mdl.animations[0].frameCount,12);assert.equal(mdl.animations[0].fps,30);
 assert.equal(await page.locator('#model-panel').isVisible(),true);assert.equal(await page.locator('#model-bone-name').inputValue(),'Root');
 const archive=Object.keys(versions).find(p=>p.endsWith('/source/rig.pkg'));assert.deepEqual(new Uint8Array(await readFile(path.join(blobRoot,versions[archive]))),modelSource().files[1].bytes);
 await command({type:'seek',time:.2});await mkdir(artifactRoot,{recursive:true});await page.screenshot({path:path.join(artifactRoot,'gltf-import.png')});
 await command({type:'undo'});assert.deepEqual((await command({type:'snapshot'})).document,original);await command({type:'redo'});assert.deepEqual((await command({type:'snapshot'})).document,snapshot);
 await command({type:'load',document:snapshot});await command({type:'seek',time:.2});const pkg=await command({type:'export-pkg',paths:Object.keys(versions)});assert(pkg.pkg.length>0);await writeFile(path.join(artifactRoot,'gltf-scene.pkg'),Buffer.from(pkg.pkg,'base64'));await writeFile(path.join(artifactRoot,'gltf-document.json'),JSON.stringify(snapshot));
 const packed=readEditorPackage(new Uint8Array(Buffer.from(pkg.pkg,'base64')));for(const file of modelSource().files){const path=Object.keys(versions).find(p=>p.endsWith('/source/'+file.path));assert.deepEqual(packed.read(path),file.bytes,'PKG must retain exact archived source bytes even for a buffer named .pkg');}
 for(const folder of ['GltfSource','GltfLoose','GltfPackage'])await mkdir(path.join(artifactRoot,folder),{recursive:true});
 const json=value=>JSON.stringify(value,null,2);await writeFile(path.join(artifactRoot,'gltf-source-command.json'),json(commandSource(modelSource())));
 await writeFile(path.join(artifactRoot,'GltfSource/project.json'),json(original.project));await writeFile(path.join(artifactRoot,'GltfSource/scene.json'),json(original.scene));
 await writeFile(path.join(artifactRoot,'GltfLoose/project.json'),json(snapshot.project));await writeFile(path.join(artifactRoot,'GltfLoose/scene.json'),json(snapshot.scene));
 for(const [relative,version] of Object.entries(versions)){const file=path.join(artifactRoot,'GltfLoose',relative);await mkdir(path.dirname(file),{recursive:true});await writeFile(file,await readFile(path.join(blobRoot,version)));}
 await writeFile(path.join(artifactRoot,'GltfPackage/project.json'),json({...snapshot.project,file:'scene.pkg'}));await writeFile(path.join(artifactRoot,'GltfPackage/scene.pkg'),Buffer.from(pkg.pkg,'base64'));
 await page.setViewportSize({width:850,height:540});
 for(const language of ['en','zh-Hans','ja','fr','es']){
  configuration.language=language;const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await page.locator('#timeline-toggle').click();
  for(const theme of ['light','dark']){
   await page.locator('#theme').selectOption(theme);await open();assert.equal(await page.locator('#gltf-error').textContent(),'');
   const layout=await page.evaluate(()=>{const dialog=document.querySelector('#gltf-dialog'),b=dialog.getBoundingClientRect();return {inside:b.left>=0&&b.right<=innerWidth&&b.top>=0&&b.bottom<=innerHeight,overflow:dialog.scrollWidth>dialog.clientWidth,focus:document.activeElement.id,labels:[...dialog.querySelectorAll('label')].every(l=>l.textContent&&!l.textContent.includes('undefined')&&l.control)};});
   assert(layout.inside&&!layout.overflow&&layout.labels,`${language}/${theme}: dialog layout/labels`);assert.equal(layout.focus,'gltf-name');await page.keyboard.press('Tab');assert(await page.evaluate(()=>document.querySelector('#gltf-dialog').contains(document.activeElement)));await page.keyboard.press('Escape');assert.deepEqual((await command({type:'snapshot'})).document,original);
  }
 }
 assert.deepEqual(errors,[]);console.log('Real glTF import: exact texture RGB, shader preview, cancel/consent, editable model, archive, history, reopen/export and five-language minimum-window layout passed');
}finally{await h.close();}
