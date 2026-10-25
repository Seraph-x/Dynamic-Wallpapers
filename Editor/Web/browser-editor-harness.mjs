import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile,mkdir,writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';

const web=path.dirname(fileURLToPath(import.meta.url)),repo=path.resolve(web,'../..');
const require=createRequire(path.join(web,'.build/package.json')),{chromium}=require('playwright');
export async function openEditorHarness(configuration) {
  const events=[],resources=new Map(),errors=[];
  const artifactRoot=process.env.EDITOR_TEST_ARTIFACTS??path.join(repo,'.build/verification/editor-browser');
  const blobRoot=path.join(artifactRoot,'PrivateResources');await mkdir(blobRoot,{recursive:true});
  let browser,page,closing=false,next=0;
  async function resourceRequest(request) {
    let result;
    try{
      if(request.action==='list'){result={paths:[...resources.keys()]};}
      else if(request.action==='stage'){
        const bytes=Buffer.from(request.data,'base64'),version=createHash('sha256').update(bytes).digest('hex');
        await writeFile(path.join(blobRoot,version),bytes);result={version};
      }else{
        assert.match(request.version,/^[a-f0-9]{64}$/);const bytes=await readFile(path.join(blobRoot,request.version));
        assert.equal(createHash('sha256').update(bytes).digest('hex'),request.version);result={data:bytes.toString('base64')};
      }
    }catch(error){result={error:String(error)};}
    if(closing)return;
    await page.evaluate(value=>window.__dynamicWallpaperEditor.command(value),{id:'resource-'+request.id,session:configuration.session,generation:configuration.generation,type:'resource-reply',requestID:request.id,result});
  }
  const mime={'.html':'text/html','.mjs':'text/javascript','.css':'text/css','.json':'application/json'};
  const server=createServer(async(request,response)=>{
    try{
      const url=new URL(request.url,'http://localhost');
      if(url.pathname==='/__editor/config'){response.setHeader('Content-Type','application/json');response.end(JSON.stringify(configuration));return;}
      if(url.pathname==='/__editor/event'&&request.method==='POST'){
        let body='';for await(const chunk of request)body+=chunk;const event=JSON.parse(body);events.push(event);response.end('{}');if(event.type==='resource')await resourceRequest(event);return;
      }
      if(url.pathname.startsWith('/__project/')){
        const bytes=resources.get(decodeURIComponent(url.pathname.slice(11)));if(!bytes){response.writeHead(404);response.end();return;}response.end(bytes);return;
      }
      assert(url.pathname.startsWith('/__runtime/'));const relative=decodeURIComponent(url.pathname.slice(11));assert(relative.split('/').every(p=>p&&p!=='.'&&p!=='..'));
      response.setHeader('Content-Type',mime[path.extname(relative)]??'application/octet-stream');response.end(await readFile(path.join(repo,'Editor/Sources/EditorApp/Resources/EditorWeb',relative)));
    }catch(error){if(!response.headersSent){response.writeHead(error.code==='ENOENT'?404:500);response.end(String(error));}else if(!closing){errors.push(String(error));}}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  async function close(){closing=true;await browser?.close();await new Promise(resolve=>server.close(resolve));}
  try{
    browser=await chromium.launch({headless:true,...(process.env.SCENE_CHROMIUM_EXECUTABLE?{executablePath:process.env.SCENE_CHROMIUM_EXECUTABLE}:{})});
    page=await browser.newPage({viewport:{width:1180,height:760}});page.on('pageerror',error=>errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/__runtime/index.html`);
    await page.waitForFunction(()=>document.querySelector('#canvas canvas'));
    const deadline=Date.now()+30000;
    while(!events.some(e=>e.type==='ready')){if(Date.now()>deadline)throw new Error('No real Editor ready: '+await page.locator('#diagnostics').textContent());await page.waitForTimeout(100);}
    return {page,resources,events,errors,artifactRoot,blobRoot,close,async command(payload){
      const id=String(++next);await page.evaluate(value=>window.__dynamicWallpaperEditor.command(value),{id,session:configuration.session,generation:configuration.generation,...payload});
      const reply=events.find(e=>e.type==='reply'&&e.id===id);assert(reply,'Native reply missing');assert(!Object.hasOwn(reply.payload,'error'),reply.payload.error);return reply.payload;
    }};
  }catch(error){await close();throw error;}
}
