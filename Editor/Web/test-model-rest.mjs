import assert from 'node:assert/strict';
import { readFile,writeFile,mkdir } from 'node:fs/promises';
import path from 'node:path';
import { openEditorHarness } from './browser-editor-harness.mjs';
import { restMatrix } from './model-math.mjs';
import { modelFixture } from './model-fixtures.mjs';
import { readMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';
import { pixels,samePose } from './test-model.mjs';
const modelPath='models/editor/rig.mdl',names=[modelPath,'models/editor/rig.json','materials/editor/rig.json','materials/editor/rig.png'];
const document={title:'Rest acceptance',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{general:{orthogonalprojection:{width:640,height:360},clearcolor:'0.05 0.05 0.08',clearenabled:true,cameraparallax:false},objects:[{id:1,name:'Rig',image:names[1],origin:'320 180 0',size:'100 30',scale:'1 1 1',angles:'0 0 0',color:'1 1 1',alpha:1}]}};
const configuration={version:1,session:'rest-acceptance',generation:1,language:'en',document:{...document,scene:{...document.scene,objects:[]}}};
const harness=await openEditorHarness(configuration);
const {page,command,resources,artifactRoot,blobRoot,errors}=harness;
const bones=bytes=>readMdlDoc(bytes).sections.find(s=>s.type==='MDLS').bones;
async function stored(snapshot){return new Uint8Array(await readFile(path.join(blobRoot,snapshot.resourceOverrides[modelPath])));}
async function exportScene(snapshot,kind){
  const exported=await command({type:'export-pkg',paths:names});
  for(const form of ['Loose','Package']){
    const directory=path.join(artifactRoot,kind+form);await mkdir(directory,{recursive:true});
    await writeFile(path.join(directory,'project.json'),JSON.stringify({...snapshot.project,file:form==='Loose'?'scene.json':'scene.pkg'}));
    if(form==='Package')await writeFile(path.join(directory,'scene.pkg'),Buffer.from(exported.pkg,'base64'));
    else{await writeFile(path.join(directory,'scene.json'),JSON.stringify(snapshot.scene));for(const name of names){const version=snapshot.resourceOverrides?.[name],target=path.join(directory,name);await mkdir(path.dirname(target),{recursive:true});await writeFile(target,version?await readFile(path.join(blobRoot,version)):resources.get(name));}}
  }
}
try{
  resources.set(modelPath,Buffer.from(modelFixture()));
  resources.set(names[1],Buffer.from(JSON.stringify({autosize:false,width:100,height:30,material:names[2],puppet:modelPath})));
  resources.set(names[2],Buffer.from(JSON.stringify({passes:[{defaultlight:false,blending:'translucent',cullmode:'nocull',depthtest:'disabled',depthwrite:'disabled',shader:'genericimage4',textures:['editor/rig']}]})));
  const green=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=80;c.height=40;const g=c.getContext('2d');g.fillStyle='#00ff00';g.fillRect(0,0,80,40);return c.toDataURL('image/png').split(',')[1];});resources.set(names[3],Buffer.from(green,'base64'));
  await command({type:'thaw'});await command({type:'load',document});await command({type:'seek',time:.5});
  await exportScene(document,'RestSource');
  await page.getByRole('button',{name:'Rig',exact:true}).click();await page.locator('#model-workspace').click();await page.locator('#model-bones button[data-bone="2"]').click();
  assert.equal(await page.locator('#model-rest-form').count(),1,'Missing existing-bone rest form');
  await page.locator('#model-show-bones').uncheck();const before=await pixels(page);
  await page.locator('#model-rest-details summary').click();assert.equal(await page.locator('#model-rest-tx').inputValue(),'35');
  await page.locator('#model-rest-tx').fill('35');assert.deepEqual((await command({type:'snapshot'})).document,document,'Unchanged rest values dirtied content');
  await page.locator('#model-rest-tx').fill('45');const frozen=await command({type:'freeze'}),saved=frozen.document;
  assert.equal(bones(await stored(saved))[2].matrix[12],45);await command({type:'thaw'});await command({type:'seek',time:.5});const changed=await pixels(page);
  assert(Math.abs(changed.halves[0].x-before.halves[0].x)<1.5,'Rest edit moved unedited left mesh');
  assert(Math.abs(changed.halves[1].x-before.halves[1].x+10*before.width/640)<1.5,`Bind X edit did not shift right mesh left by 10 units: ${JSON.stringify({before,changed})}`);
  assert(Math.abs(changed.halves[1].y-before.halves[1].y)<1.5,'Rest edit reset the existing animation');
  await command({type:'undo'});samePose(await pixels(page),before);assert.deepEqual((await command({type:'snapshot'})).document,document);
  await command({type:'redo'});samePose(await pixels(page),changed);
  await page.locator('#model-rest-sz').fill('0');await assert.rejects(command({type:'snapshot'}),/invertible/i);
  await assert.rejects(command({type:'add-image',image:{name:'Blocked',model:names[1],width:100,height:30}}),/invertible/i);
  await page.locator('#timeline-toggle').click();await page.locator('#timeline-create').click();await page.getByRole('alert').filter({hasText:/invertible/i}).waitFor();
  await page.locator('#model-rest-revert').click();assert.deepEqual((await command({type:'snapshot'})).document,saved);
  await page.locator('#model-rest-sz').fill('1e-13');const invalidFreeze=await command({type:'freeze'});assert.deepEqual(invalidFreeze.document,saved);assert.equal(invalidFreeze.dirty,true);await assert.rejects(command({type:'snapshot'}),/inverse|invertible/i);await command({type:'thaw'});await page.locator('#model-rest-revert').click();
  await page.locator('#timeline-toggle').click();
  await page.locator('#model-rest-tx').fill('46');await page.locator('#model-bone-name').fill('Rest Wing');await page.locator('#model-skin-mesh').selectOption('1');
  // Selecting a mesh prepares the rest/name drafts. Test the following rest/weight pair atomically.
  await command({type:'undo'});assert.deepEqual((await command({type:'snapshot'})).document,saved);
  await page.locator('#model-rest-tx').fill('46');await page.locator('#model-joint-0').selectOption('1');await page.locator('#model-weight-0').fill('1');
  const combined=(await command({type:'snapshot'})).document,combinedDoc=readMdlDoc(await stored(combined)),mesh=combinedDoc.meshes[1];
  assert.equal(bones(await stored(combined))[2].matrix[12],46);assert.equal(new DataView(mesh.vertexData.buffer,mesh.vertexData.byteOffset).getUint32(40,true),1);
  await command({type:'undo'});assert.deepEqual((await command({type:'snapshot'})).document,saved,'Combined rest/weight draft was not one history step');
  await page.route('**/__editor/event',async route=>{const data=route.request().postDataJSON();if(data.type==='resource'&&data.action==='stage')await route.fulfill({status:503,body:'intentional rest stage failure'});else await route.continue();});
  await page.locator('#model-rest-tx').fill('47');await page.locator('#model-rest-apply').click();await page.getByRole('alert').filter({hasText:/503/}).waitFor();
  await page.unroute('**/__editor/event');await page.locator('#model-rest-revert').click();assert.deepEqual((await command({type:'snapshot'})).document,saved,'Failed stage published rest bytes');
  await page.locator('#model-rest-tx').fill('47');await page.locator('#model-bones button[data-bone="1"]').click();await command({type:'snapshot'});assert.equal(await page.locator('#model-rest-tx').inputValue(),'-35');
  assert.equal(bones(await stored((await command({type:'snapshot'})).document))[2].matrix[12],47);await command({type:'undo'});
  await page.locator('#timeline-toggle').click();await page.locator('#timeline-create').click();await command({type:'snapshot'});
  await page.locator('.timeline-key[data-channel="0"][data-frame="0"]').click();await page.locator('#timeline-key-value').fill('330');
  await page.locator('#model-bones button[data-bone="2"]').click();await page.locator('#model-rest-tx').fill('46');await page.locator('#model-rest-apply').click();
  await page.waitForFunction(()=>!document.getElementById('model-rest-apply').matches(':disabled'));
  assert.equal(await page.locator('#timeline-key-value').inputValue(),'330','Rest edit erased the unrelated Timeline draft');
  assert.equal((await command({type:'snapshot'})).document.scene.objects[0].origin.animation.c0[0].value,330);
  await command({type:'undo'});await command({type:'undo'});await command({type:'undo'});assert.deepEqual((await command({type:'snapshot'})).document,saved);
  await page.locator('#timeline-toggle').click();
  await command({type:'mark-saved',document:saved});configuration.document=saved;
  const ready=page.waitForRequest(r=>r.method()==='POST'&&r.url().endsWith('/__editor/event')&&r.postDataJSON().type==='ready');await page.reload();await ready;await command({type:'thaw'});await command({type:'seek',time:.5});samePose(await pixels(page),changed);
  assert.deepEqual((await command({type:'snapshot'})).document,saved);await exportScene(saved,'Rest');
  for(const repair of [true,false]){
    const candidate=readMdlDoc(modelFixture()),b=candidate.sections.find(s=>s.type==='MDLS').bones;b[1].matrix=restMatrix([0,0,0,0,0,0,1,1,1e-7]);
    if(repair){b[2].parent=1;b[2].matrix=restMatrix([35,0,0,0,0,0,1,1,1e-4]);}
    resources.set(modelPath,Buffer.from(writeMdlDoc(candidate)));await command({type:'load',document});
    await page.getByRole('button',{name:'Rig',exact:true}).click();await page.locator('#model-workspace').click();await page.locator('#model-bones button[data-bone="2"]').click();
    if(!await page.locator('#model-rest-details').evaluate(e=>e.open))await page.locator('#model-rest-details summary').click();
    await page.locator('#model-rest-sz').fill('1e-6');await page.locator('#model-bone-parent').selectOption(repair?'0':'1');
    if(repair){const updated=(await command({type:'snapshot'})).document,rb=bones(await stored(updated));assert.equal(rb[2].parent,0);assert(Math.abs(rb[2].matrix[10]-1e-6)<1e-12);await command({type:'undo'});assert.deepEqual((await command({type:'snapshot'})).document,document);}
    else{await assert.rejects(command({type:'snapshot'}),/inverse|invertible/i);assert.equal(await page.locator('#model-rest-sz').inputValue(),'1e-6');await page.locator('#model-rest-revert').click();assert.deepEqual((await command({type:'snapshot'})).document,document);}
  }
  const shear=readMdlDoc(modelFixture());shear.sections.find(s=>s.type==='MDLS').bones[2].matrix[4]=.2;resources.set(modelPath,Buffer.from(writeMdlDoc(shear)));await command({type:'load',document});
  await page.getByRole('button',{name:'Rig',exact:true}).click();await page.locator('#model-workspace').click();await page.locator('#model-bones button[data-bone="2"]').click();if(!await page.locator('#model-rest-details').evaluate(e=>e.open))await page.locator('#model-rest-details summary').click();
  assert.equal(await page.locator('#model-rest-tx').isDisabled(),true);assert.match(await page.locator('#model-rest-error').textContent(),/shear/i);assert.equal(await page.locator('#model-rest-matrix').isVisible(),true);
  assert.deepEqual(errors,[]);console.log('Rest transforms: actual bind pixels, focused freeze, no-op/history, draft barriers, combined weights, stage recovery, saved reopen, loose/PKG exports and unsupported shear passed');
}finally{await harness.close();}
