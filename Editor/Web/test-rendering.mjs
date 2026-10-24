import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
const web = path.dirname(fileURLToPath(import.meta.url)), repo = path.resolve(web,'../..');
const require = createRequire(path.join(web,'.build/package.json')), {chromium} = require('playwright');
const events = [], resources = new Map();
const configuration = {version:1,session:'real-editor-test',generation:1,language:'en',document:{title:'Editor acceptance',entry:'scene.json',
  project:{type:'scene',file:'scene.json',future:{retained:true}},scene:{general:{orthogonalprojection:{width:640,height:360},clearcolor:'0.05 0.05 0.08',clearenabled:true,cameraparallax:false},objects:[]}}};
const mime = {'.html':'text/html','.mjs':'text/javascript','.css':'text/css','.json':'application/json'};
const server = createServer(async (request,response) => {
  try {
    const url = new URL(request.url,'http://localhost');
    if (url.pathname === '/__editor/config') {response.setHeader('Content-Type','application/json');response.end(JSON.stringify(configuration));return;}
    if (url.pathname === '/__editor/event' && request.method === 'POST') {let body='';for await (const chunk of request) body+=chunk;events.push(JSON.parse(body));response.end('{}');return;}
    if (url.pathname.startsWith('/__project/')) {
      const key=decodeURIComponent(url.pathname.slice(11)); const bytes=resources.get(key);
      if(!bytes) {response.writeHead(404);response.end();return;} response.end(bytes);return;
    }
    assert(url.pathname.startsWith('/__runtime/'));
    const relative=decodeURIComponent(url.pathname.slice(11)); assert(relative.split('/').every(p=>p && p!=='.' && p!=='..'));
    response.setHeader('Content-Type',mime[path.extname(relative)]??'application/octet-stream');
    response.end(await readFile(path.join(repo,'Editor/Sources/EditorApp/Resources/EditorWeb',relative)));
  } catch(error) {response.writeHead(error.code==='ENOENT'?404:500);response.end(String(error));}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try {
  browser=await chromium.launch({headless:true,...(process.env.SCENE_CHROMIUM_EXECUTABLE?{executablePath:process.env.SCENE_CHROMIUM_EXECUTABLE}:{})});
  const page=await browser.newPage({viewport:{width:1180,height:760}}),errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/__runtime/index.html`);
  await page.waitForFunction(()=>document.querySelector('#canvas canvas'));
  const deadline=Date.now()+30000;
  while(!events.some(e=>e.type==='ready')) {if(Date.now()>deadline)throw new Error('No real Editor ready: '+await page.locator('#diagnostics').textContent());await page.waitForTimeout(100);}
  let next=0;
  async function command(payload) {
    const id=String(++next); await page.evaluate(value=>window.__dynamicWallpaperEditor.command(value),{id,session:configuration.session,generation:1,...payload});
    const reply=events.find(e=>e.type==='reply'&&e.id===id);assert(reply,'Native reply missing');assert(!reply.payload.error,reply.payload.error);return reply.payload;
  }
  await command({type:'thaw'});await page.locator('#playback').click();
  await page.locator('#add-text').click();await command({type:'snapshot'});
  assert.equal(await page.locator('#diagnostics').textContent(),'','Text layer rendering failed');
  await page.getByRole('button',{name:'Text',exact:true}).click();
  await page.locator('#field-text').fill('Real scene text');
  let snapshot=(await command({type:'snapshot'})).document;
  assert.equal(snapshot.scene.objects[0].text,'Real scene text');
  const canvas=page.locator('#canvas canvas');const first=await canvas.screenshot();
  await page.locator('#field-color').fill('1 0 0');await command({type:'snapshot'});
  const red=await canvas.screenshot();assert.notDeepEqual(first,red,'Color edit must change real pixels');
  await command({type:'undo'});assert.deepEqual(await canvas.screenshot(),first,'Undo must restore pixels');
  await command({type:'redo'});assert.deepEqual(await canvas.screenshot(),red,'Redo must restore edited pixels');
  const png=await page.evaluate(()=>{const canvas=document.createElement('canvas');canvas.width=80;canvas.height=40;const ctx=canvas.getContext('2d');ctx.fillStyle='#00ff00';ctx.fillRect(0,0,80,40);return canvas.toDataURL('image/png').split(',')[1];});
  resources.set('materials/editor/green.png',Buffer.from(png,'base64'));
  resources.set('models/editor/green.json',Buffer.from(JSON.stringify({material:'materials/editor/green.json',width:80,height:40})));
  resources.set('materials/editor/green.json',Buffer.from(JSON.stringify({passes:[{blending:'translucent',cullmode:'nocull',depthtest:'disabled',depthwrite:'disabled',shader:'genericimage2',textures:['editor/green']}]})));
  await command({type:'add-image',image:{name:'Green image',model:'models/editor/green.json',width:80,height:40}});
  snapshot=(await command({type:'snapshot'})).document;assert.equal(snapshot.scene.objects.length,2);assert(snapshot.project.future.retained);
  assert.notDeepEqual(await canvas.screenshot(),red,'Image layer must render real pixels');
  const beforeDrag=snapshot.scene.objects[1].origin, bounds=await canvas.boundingBox();
  await page.mouse.move(bounds.x+bounds.width/2,bounds.y+bounds.height/2);await page.mouse.down();
  await page.mouse.move(bounds.x+bounds.width/2+70,bounds.y+bounds.height/2-20,{steps:5});await page.mouse.up();
  snapshot=(await command({type:'snapshot'})).document;
  assert.notEqual(snapshot.scene.objects[1].origin,beforeDrag,'Canvas drag must commit a transform');
  const dragged=snapshot.scene.objects[1].origin;
  await command({type:'undo'});assert.equal((await command({type:'snapshot'})).document.scene.objects[1].origin,beforeDrag);
  await command({type:'redo'});assert.equal((await command({type:'snapshot'})).document.scene.objects[1].origin,dragged);
  const exported=await command({type:'export-pkg',paths:[...resources.keys()]});assert(Buffer.from(exported.pkg,'base64').includes(Buffer.from('PKGV0012')));
  await page.locator('#project-title').fill('Unblurred title');
  const frozen=await command({type:'freeze'});assert.equal(frozen.document.title,'Unblurred title');assert.equal(frozen.dirty,true);
  assert.equal(await page.evaluate(()=>document.body.inert),true);
  await page.keyboard.press('Meta+z');assert.deepEqual((await command({type:'snapshot'})).document,frozen.document,'Frozen keyboard changed document');
  await command({type:'thaw'});
  const saved=(await command({type:'snapshot'})).document;
  await page.locator('#project-title').fill('Typed during preview completion');
  await command({type:'mark-saved',document:saved});
  assert.equal(await page.locator('#project-title').inputValue(),'Typed during preview completion','Async update erased focused input');
  assert.equal((await command({type:'freeze'})).document.title,'Typed during preview completion');
  await command({type:'thaw'});
  const artifactRoot=process.env.EDITOR_TEST_ARTIFACTS??path.join(repo,'.build/verification/editor-browser');await mkdir(artifactRoot,{recursive:true});
  await writeFile(path.join(artifactRoot,'scene.pkg'),Buffer.from(exported.pkg,'base64'));
  await writeFile(path.join(artifactRoot,'scene.json'),JSON.stringify(snapshot.scene));await writeFile(path.join(artifactRoot,'project.json'),JSON.stringify({...snapshot.project,title:snapshot.title,file:'scene.pkg'}));
  for (const form of ['Loose','Package']) {
    const directory=path.join(artifactRoot,form);await mkdir(directory,{recursive:true});
    await writeFile(path.join(directory,'project.json'),JSON.stringify({...snapshot.project,title:snapshot.title,file:form==='Loose'?'scene.json':'scene.pkg'}));
    if(form==='Package') await writeFile(path.join(directory,'scene.pkg'),Buffer.from(exported.pkg,'base64'));
    else {
      await writeFile(path.join(directory,'scene.json'),JSON.stringify(snapshot.scene));
      for(const [name,data] of resources) {const target=path.join(directory,name);await mkdir(path.dirname(target),{recursive:true});await writeFile(target,data);}
    }
  }
  await page.screenshot({path:path.join(artifactRoot,'editor.png')});
  await page.locator('#field-visible').uncheck();
  assert.equal((await command({type:'snapshot'})).document.scene.objects[1].visible,false);
  await page.getByRole('button',{name:'Green image (Hidden layer)',exact:true}).waitFor({state:'visible'});
  assert.equal(await page.locator('#layers button[data-visible="false"]').evaluate(element=>getComputedStyle(element).opacity),'1','Hidden layers must retain readable text');
  await page.locator('#field-visible').check(); await command({type:'snapshot'});
  const beforeAppearance=(await command({type:'snapshot'})).document;
  await page.emulateMedia({colorScheme:'light'});
  await page.locator('#theme').selectOption('system');
  const lightBackground=await page.evaluate(()=>getComputedStyle(document.documentElement).backgroundColor);
  await page.emulateMedia({colorScheme:'dark'});
  const darkBackground=await page.evaluate(()=>getComputedStyle(document.documentElement).backgroundColor);
  assert.notEqual(lightBackground,darkBackground,'System appearance must follow OS changes');
  await page.locator('#theme').selectOption('light');
  assert.equal(await page.evaluate(()=>getComputedStyle(document.documentElement).backgroundColor),lightBackground);
  await page.locator('#theme').selectOption('dark');
  await page.emulateMedia({colorScheme:'light'});
  assert.equal(await page.evaluate(()=>getComputedStyle(document.documentElement).backgroundColor),darkBackground,'Explicit theme must remain independent from OS');
  assert.deepEqual((await command({type:'snapshot'})).document,beforeAppearance,'Appearance changed scene content');
  await page.setViewportSize({width:850,height:540});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'Minimum native window has horizontal overflow');
  assert.equal(await page.locator('#theme').isVisible(),true);
  assert.equal(await page.locator('#playback').isVisible(),true);
  await page.screenshot({path:path.join(artifactRoot,'editor-dark-compact.png')});
  await page.setViewportSize({width:1180,height:760});
  await page.locator('#theme').selectOption('light');
  await page.getByRole('button',{name:'Green image',exact:true}).click();
  await page.screenshot({path:path.join(artifactRoot,'editor-light.png')});
  configuration.document=beforeAppearance;
  for (const language of ['en','zh-Hans','ja','fr','es']) {
    configuration.language=language;
    const ready=page.waitForRequest(request=>request.method()==='POST' && request.url().endsWith('/__editor/event') && request.postDataJSON().type==='ready');
    await page.reload(); await ready; await command({type:'thaw'});
    await page.setViewportSize({width:850,height:540});
    const layout=await page.evaluate(()=>{
      const box=selector=>document.querySelector(selector).getBoundingClientRect();
      return {brand:box('.brand').right,title:box('.project-heading').left,titleRight:box('.project-heading').right,actions:box('.header-actions').left,
        layers:box('.layers-panel').right,canvas:box('#preview').left,canvasRight:box('#preview').right,properties:box('.properties-panel').left,
        undefinedLabels:[...document.querySelectorAll('[data-text],[data-label]')].some(element=>element.textContent==='undefined'||element.getAttribute('aria-label')==='undefined')};
    });
    assert(layout.brand<=layout.title && layout.titleRight<=layout.actions,`${language}: overlapping header controls`);
    assert(layout.layers<=layout.canvas && layout.canvasRight<=layout.properties,`${language}: overlapping workspace panels`);
    assert.equal(layout.undefinedLabels,false,`${language}: missing interface text`);
    await page.locator('#theme').selectOption('dark'); await page.locator('#theme').selectOption('light');
  }
  assert.equal((await page.locator('#diagnostics').textContent()),'');assert.deepEqual(errors,[]);
  console.log('Real Editor: edits, pixels, undo/redo, exports, hidden layers, appearance and five-language minimum-window layout passed');
} finally {await browser?.close();await new Promise(resolve=>server.close(resolve));}
