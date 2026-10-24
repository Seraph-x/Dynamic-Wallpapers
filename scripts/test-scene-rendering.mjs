#!/usr/bin/env node
// Real browser engine test. npm ci --prefix scripts/scene-runtime-build first.
// SCENE_CHROMIUM_EXECUTABLE may select an explicitly installed Chromium binary.
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(path.join(root, 'scripts/scene-runtime-build/package.json'));
const { chromium } = require('playwright');
let representation = 'loose';
const events = [];
const mime = { '.html': 'text/html', '.css': 'text/css', '.mjs': 'text/javascript', '.json': 'application/json', '.pkg': 'application/octet-stream' };
const server = createServer(async (request, response) => {
  try {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    if (pathname === '/__scene/config') {
      response.setHeader('Content-Type', 'application/json');
      response.end(JSON.stringify({ version: 1, sceneID: 'render-test', generation: 1, project: { representation, entryPath: representation === 'loose' ? 'scene.json' : 'scene.pkg' }, viewport: { width: 640, height: 360 }, fps: 30, fit: 'cover', volume: 1, muted: true })); return;
    }
    if (pathname === '/__scene/event' && request.method === 'POST') {
      let body = ''; for await (const chunk of request) body += chunk;
      events.push(JSON.parse(body)); response.end(''); return;
    }
    let directory, name;
    if (pathname.startsWith('/__runtime/')) { directory = 'Sources/WallpaperApp/Resources/SceneRuntime'; name = pathname.slice(11); }
    else if (pathname.startsWith('/__project/')) { directory = `Tests/Fixtures/SceneAnimated${representation === 'loose' ? 'Loose' : 'Package'}`; name = pathname.slice(11); }
    else { response.writeHead(404); response.end(); return; }
    assert.ok(name && name.split('/').every(part => part && part !== '.' && part !== '..'));
    const file = path.join(root, directory, decodeURIComponent(name));
    response.setHeader('Content-Type', mime[path.extname(file)] ?? 'application/octet-stream'); response.end(await readFile(file));
  } catch (error) {
    response.writeHead(error.code === 'ENOENT' ? 404 : 500); response.end(String(error));
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let browser;
try {
  browser = await chromium.launch({ headless: true, ...(process.env.SCENE_CHROMIUM_EXECUTABLE ? { executablePath: process.env.SCENE_CHROMIUM_EXECUTABLE } : {}) });
  for (const form of ['loose', 'package']) {
    representation = form; events.length = 0;
    const page = await browser.newPage({ viewport: { width: 640, height: 360 }, deviceScaleFactor: 1 });
    const errors = [];
    page.on('response', response => { if (response.status() >= 400) console.error('HTTP failure', response.status(), response.url()); });
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    await page.goto(`http://127.0.0.1:${server.address().port}/__runtime/index.html`);
    await assert.doesNotReject(page.waitForFunction(() => !!window.__dynamicWallpaperScene), { message: 'Trusted command entry missing' });
    await assert.doesNotReject((async () => { for (let attempt = 0; attempt < 100; attempt++) { if (events.some(event => event.type === 'ready')) return; if (events.some(event => event.type === 'error')) throw new Error(JSON.stringify(events)); await new Promise(resolve => setTimeout(resolve, 100)); } throw new Error('Real engine did not produce ready within 10 seconds'); })());
    assert.deepEqual(errors, []);
    const capture = () => page.screenshot({ animations: 'allow' });
    const first = await capture(); await page.waitForTimeout(250); const second = await capture();
    assert.notDeepEqual(first, second, `${form}: animated scene pixels must change`);
    let next = 0;
    const command = async payload => {
      const id = String(++next);
      await page.evaluate(value => window.__dynamicWallpaperScene.command(value), { id, sceneID: 'render-test', generation: 1, ...payload });
      assert.ok(events.some(event => event.type === 'command-ack' && event.commandID === id));
    };
    await command({ type: 'pause' }); await page.waitForTimeout(100);
    const paused = await capture(); await page.waitForTimeout(250);
    assert.deepEqual(paused, await capture(), `${form}: paused scene must preserve pixels`);
    await command({ type: 'play' }); await page.waitForTimeout(100);
    const resumedFirst = await capture(); await page.waitForTimeout(250);
    const resumedSecond = await capture();
    // An oscillating object can revisit the paused coordinate. Two separated
    // resumed samples must establish motion rather than rely on one phase.
    assert.notDeepEqual(resumedFirst, resumedSecond, `${form}: resumed scene must animate`);
    const colors = async png => page.evaluate(async encoded => {
      const image = new Image(); image.src = `data:image/png;base64,${encoded}`; await image.decode();
      const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
      const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
      let cyan = 0, x = 0, y = 0, green = 0, yellow = 0;
      for (let index = 0; index < pixels.length; index += 4) {
        if (pixels[index] < 100 && pixels[index + 1] > 150 && pixels[index + 2] > 150) {
          cyan++; x += index / 4 % canvas.width; y += Math.floor(index / 4 / canvas.width);
        }
        if (pixels[index] < 80 && pixels[index + 1] > 150 && pixels[index + 2] < 80) green++;
        if (pixels[index] > 150 && pixels[index + 1] > 150 && pixels[index + 2] < 80) yellow++;
      }
      return { cyan, x: x / cyan, y: y / cyan, green, yellow };
    }, png.toString('base64'));
    await command({ type: 'pointer', kind: 'move', x: .1, y: .8 }); await page.waitForTimeout(50);
    await command({ type: 'play' }); await page.waitForTimeout(100); await command({ type: 'pause' });
    const pointerFirst = await colors(await capture());
    await command({ type: 'pointer', kind: 'move', x: .8, y: .2 });
    await command({ type: 'play' }); await page.waitForTimeout(100); await command({ type: 'pause' });
    const pointerSecond = await colors(await capture());
    assert.ok(pointerFirst.cyan > 100 && pointerSecond.cyan > 100, `${form}: authored pointer marker must render`);
    assert.ok(pointerSecond.x - pointerFirst.x > 300 && pointerFirst.y - pointerSecond.y > 150, `${form}: injected pointer must move the cyan marker`);
    assert.ok(pointerFirst.green > 100 && pointerSecond.green > 100, `${form}: spectrum fixture must stay green with zero audio input`);
    await command({ type: 'play' });
    await command({ type: 'pointer', kind: 'click', x: .875, y: 320 / 360 });
    await command({ type: 'pause' });
    assert.ok((await colors(await capture())).yellow > 1000, `${form}: left click must trigger the authored cursorClick hook`);
    const renderer = await page.evaluate(() => { const canvas = document.querySelector('canvas'); const gl = canvas.getContext('webgl2'); const extension = gl.getExtension('WEBGL_debug_renderer_info'); return { width: canvas.width, height: canvas.height, vendor: gl.getParameter(extension.UNMASKED_VENDOR_WEBGL), renderer: gl.getParameter(extension.UNMASKED_RENDERER_WEBGL) }; });
    console.log(JSON.stringify({ representation: form, ...renderer, events: events.map(value => value.type), errors }));
    await command({ type: 'destroy' }); await page.close();
  }
} finally {
  await browser?.close(); await new Promise(resolve => server.close(resolve));
}
