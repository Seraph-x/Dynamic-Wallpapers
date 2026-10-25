import assert from 'node:assert/strict';
import { readFile,writeFile,mkdir } from 'node:fs/promises';
import path from 'node:path';
import { modelFixture,modelSpec } from './model-fixtures.mjs';
import { createMdlDoc,writeMdlDoc } from './vendor/mdl-codec.mjs';
import { testModelWorkspace } from './test-model-workspace.mjs';
import { testModelRecovery } from './test-model-recovery.mjs';
import { testModelLayout } from './test-model-layout.mjs';

// Read committed screenshots, rather than an unpreserved WebGL drawing buffer.
export async function pixels(page) {
  const bytes=await page.locator('#canvas canvas').screenshot();
  return page.evaluate(async bytes=>{
    const bitmap=await createImageBitmap(new Blob([new Uint8Array(bytes)],{type:'image/png'}));
    const canvas=document.createElement('canvas');canvas.width=bitmap.width;canvas.height=bitmap.height;
    const ctx=canvas.getContext('2d');ctx.drawImage(bitmap,0,0);bitmap.close();
    const data=ctx.getImageData(0,0,canvas.width,canvas.height).data,halves=[{n:0,x:0,y:0},{n:0,x:0,y:0}];
    for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){
      const p=(y*canvas.width+x)*4;
      if(data[p+1]>180 && data[p]<70 && data[p+2]<70){const half=halves[x<canvas.width/2?0:1];half.n++;half.x+=x;half.y+=y;}
    }
    return {width:canvas.width,height:canvas.height,halves:halves.map(h=>({n:h.n,x:h.x/h.n,y:h.y/h.n}))};
  },[...bytes]);
}
export function samePose(actual,expected) {
  actual.halves.forEach((h,i)=>{
    assert(h.n>100,'Model mesh has no actual green pixels');
    assert(Math.abs(h.x-expected.halves[i].x)<1.5 && Math.abs(h.y-expected.halves[i].y)<1.5,`Bone edit changed surviving mesh deformation: ${JSON.stringify({actual,expected})}`);
  });
}
export async function testModel({page,command,resources,configuration,artifactRoot,blobRoot}) {
  const modelPath='models/editor/rig.mdl',names=[modelPath,'models/editor/rig.json','materials/editor/rig.json','materials/editor/rig.png'];
  resources.set(modelPath,Buffer.from(modelFixture()));
  resources.set(names[1],Buffer.from(JSON.stringify({autosize:false,width:100,height:30,material:names[2],puppet:modelPath})));
  resources.set(names[2],Buffer.from(JSON.stringify({passes:[{defaultlight:false,blending:'translucent',cullmode:'nocull',depthtest:'disabled',depthwrite:'disabled',shader:'genericimage4',textures:['editor/rig']}]})));
  resources.set(names[3],resources.get('materials/editor/green.png'));
  const document={title:'Skeleton acceptance',entry:'scene.json',project:{type:'scene',file:'scene.json'},scene:{
    general:{orthogonalprojection:{width:640,height:360},clearcolor:'0.05 0.05 0.08',clearenabled:true,cameraparallax:false},
    objects:[{id:1,name:'Rig',image:names[1],origin:'320 180 0',size:'100 30',scale:'1 1 1',angles:'0 0 0',color:'1 1 1',alpha:1}]}};
  await command({type:'load',document});
  const bytes=await page.evaluate(async spec=>{
    const {encodeMdl}=await import('./editor-api.mjs');
    const typed={...spec,meshes:spec.meshes.map(m=>({...m,positions:Float32Array.from(m.positions),uvs:Float32Array.from(m.uvs),indices:Uint32Array.from(m.indices),boneIdx:Uint32Array.from(m.boneIdx),weights:Float32Array.from(m.weights)})),
      bones:spec.bones.map(b=>({...b,matrix:Float32Array.from(b.matrix)})),animations:spec.animations.map(a=>({...a,tracks:a.tracks.map(t=>Float32Array.from(t))}))};
    return [...encodeMdl(typed)];
  },JSON.parse(JSON.stringify(modelSpec(),(_,v)=>ArrayBuffer.isView(v)?[...v]:v)));
  assert.deepEqual(new Uint8Array(bytes),writeMdlDoc(createMdlDoc(modelSpec())),'Vendored codec differs from the pinned engine encoder');
  await command({type:'seek',time:0});const start=await pixels(page);
  await command({type:'seek',time:.5});const middle=await pixels(page);
  assert(start.halves.every(h=>h.n>100) && middle.halves.every(h=>h.n>100),'Both real skinned meshes must render');
  assert(Math.abs(start.halves[0].y-middle.halves[0].y)<1.5,'Static left bone moved');
  assert(Math.abs(start.halves[1].y-middle.halves[1].y-30*start.width/640)<2,'Intermediate right-bone deformation differs from known animation');
  const authored=await testModelWorkspace(page,command,modelPath);
  const authoredBytes=new Uint8Array(await readFile(path.join(blobRoot,authored.resourceOverrides[modelPath])));
  await testModelRecovery(page,command,modelPath,authoredBytes);
  await testModelLayout(page,command,configuration,authored);
  await command({type:'seek',time:.5});
  const edited=await page.evaluate(async bytes=>{
    const {rewriteSkeleton}=await import('./model-api.mjs');
    return [...rewriteSkeleton(new Uint8Array(bytes),{boneLimit:3,bones:[{source:0,parent:-1},{source:2,parent:0},{source:1,parent:0}]}).bytes];
  },[...authoredBytes]);
  await command({type:'replace-resource',path:modelPath,data:Buffer.from(edited).toString('base64')});samePose(await pixels(page),middle);
  await command({type:'undo'});samePose(await pixels(page),middle);
  await command({type:'redo'});samePose(await pixels(page),middle);
  const weights=await page.evaluate(async bytes=>{
    const {setSkinInfluences}=await import('./model-api.mjs');
    return [...setSkinInfluences(new Uint8Array(bytes),{boneLimit:3,mesh:1,edits:[0,1,2,3].map(vertex=>({vertex,influences:[{joint:2,weight:1}]}))})];
  },edited);
  await command({type:'replace-resource',path:modelPath,data:Buffer.from(weights).toString('base64')});samePose(await pixels(page),start);
  await command({type:'undo'});samePose(await pixels(page),middle);
  const saved=(await command({type:'snapshot'})).document;
  await command({type:'mark-saved',document:saved});
  const workspace=path.join(artifactRoot,'model-workspace.json');await writeFile(workspace,JSON.stringify(saved));
  configuration.document=JSON.parse(await readFile(workspace,'utf8'));
  const ready=page.waitForRequest(r=>r.method()==='POST' && r.url().endsWith('/__editor/event') && r.postDataJSON().type==='ready');
  await page.reload();await ready;await command({type:'thaw'});await command({type:'seek',time:.5});samePose(await pixels(page),middle);
  assert.deepEqual((await command({type:'snapshot'})).document,saved,'Reopen lost the model resource revision');
  const exported=await command({type:'export-pkg',paths:names});
  for(const form of ['Loose','Package']){
    const directory=path.join(artifactRoot,'Model'+form);await mkdir(directory,{recursive:true});
    await writeFile(path.join(directory,'project.json'),JSON.stringify({...saved.project,file:form==='Loose'?'scene.json':'scene.pkg'}));
    if(form==='Package')await writeFile(path.join(directory,'scene.pkg'),Buffer.from(exported.pkg,'base64'));
    else {
      await writeFile(path.join(directory,'scene.json'),JSON.stringify(saved.scene));
      for(const name of names){const version=saved.resourceOverrides?.[name],target=path.join(directory,name);await mkdir(path.dirname(target),{recursive:true});await writeFile(target,version?await readFile(path.join(blobRoot,version)):resources.get(name));}
    }
  }
  console.log('Real model: pinned encoder, intermediate deformation, reindex/weights, undo/redo, saved-resource reopen and model loose/PKG export passed');
}
