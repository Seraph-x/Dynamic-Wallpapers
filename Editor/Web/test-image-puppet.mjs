import assert from 'node:assert/strict';
import { mkdir,writeFile,readFile } from 'node:fs/promises';
import path from 'node:path';
import { testImagePuppetLayout } from './test-image-puppet-layout.mjs';
import { openEditorHarness } from './browser-editor-harness.mjs';
import { readMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';

const encode=value=>Buffer.from(JSON.stringify(value));
// Compare scene pixels independently of SVG controls and rounded UI clipping.
const sceneCapture={style:'#model-bone-overlay { visibility:hidden } .canvas-stage { border-radius:0 }'};
const sourceModel='models/editor/picture.json',sourceMaterial='materials/editor/picture.json';
const original={title:'Image authoring',entry:'scene.json',project:{type:'scene',file:'scene.json',future:true},scene:{
  general:{orthogonalprojection:{width:640,height:360},clearcolor:'0.05 0.05 0.08',clearenabled:true,cameraparallax:false},objects:[
    {id:1,name:'Picture',image:sourceModel,origin:'320 180 0',scale:'1 1 1',angles:'0 0 0',color:'1 1 1',alpha:1,future:{retained:true}},
    {id:2,name:'Shared image',image:sourceModel,origin:'480 180 0',visible:false},
    {id:3,name:'Autosized image',image:'models/editor/auto.json',origin:'480 250 0',visible:false}]}};
const configuration={version:1,session:'image-puppet-test',generation:1,language:'en',document:{...original,scene:{...original.scene,objects:[]}}};
const harness=await openEditorHarness(configuration),{page,command,resources,artifactRoot,blobRoot,errors}=harness;
async function selectPicture(){await page.locator('#layers button[data-layer-id="1"]').click();await command({type:'snapshot'});await page.locator('#model-workspace').click();}
async function openCreation(){await page.locator('#model-image-create').click();await page.locator('#model-image-root').waitFor();}
async function redBounds(){
  const bytes=await page.locator('#canvas canvas').screenshot(sceneCapture);
  return page.evaluate(async bytes=>{
    const image=await createImageBitmap(new Blob([new Uint8Array(bytes)],{type:'image/png'})),canvas=document.createElement('canvas');canvas.width=image.width;canvas.height=image.height;
    const ctx=canvas.getContext('2d');ctx.drawImage(image,0,0);image.close();const data=ctx.getImageData(0,0,canvas.width,canvas.height).data;let min=Infinity,count=0;
    for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){const p=(y*canvas.width+x)*4;if(data[p]>180&&data[p+1]<70&&data[p+2]<70){min=Math.min(min,x);count++;}}
    return {min,count,scale:Math.min(canvas.width/640,canvas.height/360)};
  },[...bytes]);
}
try{
  const png=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=80;c.height=40;const ctx=c.getContext('2d');
    for(const [color,x,y] of [['#ff0000',0,0],['#00ff00',40,0],['#0000ff',0,20],['#ffff00',40,20]]){ctx.fillStyle=color;ctx.fillRect(x,y,40,20);}return c.toDataURL('image/png').split(',')[1];});
  const model={width:80,height:40,material:sourceMaterial,future:{kept:true}},material={passes:[{shader:'genericimage2',textures:['editor/picture'],blending:'translucent',cullmode:'nocull',depthtest:'disabled',depthwrite:'disabled'}],future:{kept:true}};
  resources.set(sourceModel,encode(model));resources.set(sourceMaterial,encode(material));resources.set('materials/editor/picture.png',Buffer.from(png,'base64'));
  resources.set('models/editor/auto.json',encode({...model,autosize:true}));
  await command({type:'thaw'});await command({type:'load',document:original});await command({type:'seek',time:0});await selectPicture();
  await page.locator('#layers button[data-layer-id="3"]').click();await command({type:'snapshot'});await openCreation();
  await page.locator('#model-image-confirm').click();await page.locator('#model-image-error').filter({hasText:/Autosized/}).waitFor();
  await page.locator('#model-image-cancel').click();await page.waitForFunction(()=>document.querySelector('#diagnostics').textContent==='');
  assert.deepEqual((await command({type:'snapshot'})).document,original);await selectPicture();
  const canvas=page.locator('#canvas canvas'),before=await canvas.screenshot(sceneCapture);
  await openCreation();assert.equal(await page.locator('#model-image-root').inputValue(),'Root');
  await assert.rejects(command({type:'snapshot'}),/Finish or cancel the model dialog/);
  await page.locator('#model-image-cancel').click();await page.waitForFunction(()=>document.querySelector('#diagnostics').textContent==='');assert.deepEqual((await command({type:'snapshot'})).document,original);
  // Fail the second real stage request. The first immutable blob may remain,
  // but no selected layer/resource map is published and Cancel stays usable.
  let staged=0;
  const failStage=async route=>{const r=route.request(),e=r.method()==='POST'?r.postDataJSON():undefined;
    if(e?.type==='resource'&&e.action==='stage'&&++staged===2)await route.fulfill({status:503,body:'Injected stage failure'});else await route.continue();};
  await page.route('**/__editor/event',failStage);await openCreation();await page.locator('#model-image-confirm').click();
  await page.locator('#model-image-error').filter({hasText:/503/}).waitFor();await page.unroute('**/__editor/event',failStage);await page.locator('#model-image-cancel').click();await page.waitForFunction(()=>document.querySelector('#diagnostics').textContent==='');
  assert.deepEqual((await command({type:'snapshot'})).document,original,'Failed conversion published partial data');
  const sized=structuredClone(original);sized.scene.objects[0].size={value:'160 80'};sized.scene.objects[0].alignment='top';
  await command({type:'load',document:sized});await selectPicture();const sizedPixels=await canvas.screenshot(sceneCapture);
  await openCreation();await page.locator('#model-image-confirm').click();await command({type:'snapshot'});
  assert.deepEqual(await canvas.screenshot(sceneCapture),sizedPixels,'Explicit image size/alignment changed during conversion');
  await command({type:'undo'});assert.deepEqual((await command({type:'snapshot'})).document,sized);
  await command({type:'load',document:original});await selectPicture();
  await openCreation();await page.locator('#model-image-root').fill('Anchor');await page.locator('#model-image-grid-4').check();await page.locator('#model-image-confirm').click();
  const converted=(await command({type:'snapshot'})).document;assert.equal(Object.keys(converted.resourceOverrides).length,3);
  assert.deepEqual(converted.scene.objects.slice(1),original.scene.objects.slice(1));assert.deepEqual({...converted.scene.objects[0],image:sourceModel},original.scene.objects[0]);
  assert.notEqual(converted.scene.objects[0].image,sourceModel);assert.equal(await page.locator('#model-bones button').count(),1);
  assert.equal(await page.locator('#model-bone-name').inputValue(),'Anchor');
  await writeFile(path.join(artifactRoot,'image-before.png'),before);await writeFile(path.join(artifactRoot,'image-after.png'),await canvas.screenshot(sceneCapture));
  assert.deepEqual(await canvas.screenshot(sceneCapture),before,'Generated mesh changed source image pixels or orientation');
  await command({type:'undo'});assert.deepEqual((await command({type:'snapshot'})).document,original);assert.deepEqual(await canvas.screenshot(sceneCapture),before);
  await command({type:'redo'});assert.deepEqual((await command({type:'snapshot'})).document,converted);assert.deepEqual(await canvas.screenshot(sceneCapture),before);
  assert.deepEqual(resources.get(sourceModel),encode(model));assert.deepEqual(resources.get(sourceMaterial),encode(material));
  await page.locator('#model-create').click();await page.locator('#model-new-name').fill('Fixed');await page.locator('#model-new-parent').selectOption('-1');await page.locator('#model-new-confirm').click();
  let state=(await command({type:'snapshot'})).document;
  const generatedModel=JSON.parse(await readFile(path.join(blobRoot,state.resourceOverrides[state.scene.objects[0].image]),'utf8')),mdlPath=generatedModel.puppet;
  const mdl=readMdlDoc(new Uint8Array(await readFile(path.join(blobRoot,state.resourceOverrides[mdlPath]))));
  // Test-only dense native animation fixture; this does not claim clip UI.
  const clip=mdl.sections.find(s=>s.type==='MDLA').anims[0];clip.name='Test root motion';clip.mode='mirror';clip.fps=1;
  clip.tracks[0].data=Float32Array.of(0,0,0,0,0,0,1,1,1,20,0,0,0,0,0,1,1,1);
  await command({type:'replace-resource',path:mdlPath,data:Buffer.from(writeMdlDoc(mdl)).toString('base64')});await command({type:'seek',time:.5});
  const moving=await canvas.screenshot(sceneCapture),bounds=await redBounds();assert(bounds.count>100);
  await page.locator('#model-joint-0').selectOption('1');await page.locator('#model-weight-0').fill('1');await page.locator('#model-weights-apply').click();await command({type:'snapshot'});
  const changed=await redBounds();assert(bounds.min-changed.min>=5*bounds.scale&&bounds.min-changed.min<=11*bounds.scale,'Numeric weights did not produce the known fixed-corner deformation');
  await command({type:'undo'});assert.deepEqual(await canvas.screenshot(sceneCapture),moving);
  state=(await command({type:'snapshot'})).document;await command({type:'mark-saved',document:state});
  await writeFile(path.join(artifactRoot,'image-workspace.json'),JSON.stringify(state));configuration.document=JSON.parse(await readFile(path.join(artifactRoot,'image-workspace.json'),'utf8'));
  const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await command({type:'seek',time:.5});assert.deepEqual(await canvas.screenshot(sceneCapture),moving);
  const all=[...new Set([...resources.keys(),...Object.keys(state.resourceOverrides)])],exported=await command({type:'export-pkg',paths:all});
  for(const form of ['Source','Loose','Package']){
    const dir=path.join(artifactRoot,'Image'+form);await mkdir(dir,{recursive:true});const value=form==='Source'?original:state;
    await writeFile(path.join(dir,'project.json'),JSON.stringify({...value.project,file:form==='Package'?'scene.pkg':'scene.json'}));
    if(form==='Package')await writeFile(path.join(dir,'scene.pkg'),Buffer.from(exported.pkg,'base64'));
    else{await writeFile(path.join(dir,'scene.json'),JSON.stringify(value.scene));for(const name of form==='Source'?[...resources.keys()]:all){const version=value.resourceOverrides?.[name],target=path.join(dir,name);await mkdir(path.dirname(target),{recursive:true});await writeFile(target,version?await readFile(path.join(blobRoot,version)):resources.get(name));}}
  }
  await testImagePuppetLayout(page,command,configuration,original);
  assert.deepEqual(errors,[]);assert.equal(await page.locator('#diagnostics').textContent(),'');
  console.log('Image puppet: exact image pixels, cancel/stage failure, shared isolation, one-step history, UI bones/weights with known test motion, saved reload and loose/PKG exports passed');
}finally{await harness.close();}
