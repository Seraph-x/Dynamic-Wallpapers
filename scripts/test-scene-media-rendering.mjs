import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { emptyMedia, ownedMedia, mediaFixture, mediaPackage } from './system-media-fixture.mjs';
const require = createRequire(new URL('./scene-runtime-build/package.json', import.meta.url));
const { chromium } = require('playwright');
const events = [];
const runtimeRoot = process.env.SCENE_MEDIA_RUNTIME_ROOT ?? 'Sources/WallpaperApp/Resources/SceneRuntime';
let representation = 'loose';
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://localhost');
    if (url.pathname === '/favicon.ico') { response.writeHead(204); return response.end(); }
    response.setHeader('Content-Type', url.pathname.endsWith('.mjs') ? 'text/javascript' : url.pathname.endsWith('.html') ? 'text/html' : url.pathname.endsWith('.css') ? 'text/css' : 'application/json');
    if (url.pathname === '/__scene/config') return response.end(JSON.stringify({ version: 1, sceneID: 'owned-media', generation: 1,
      project: { representation, entryPath: representation === 'loose' ? 'scene.json' : 'scene.pkg' },
      viewport: { width: 640, height: 360 }, fps: 30, fit: 'cover', volume: 1, muted: true }));
    if (url.pathname === '/__scene/spectrum') return response.end(JSON.stringify({ sceneID: 'owned-media', generation: 1, left: Array(64).fill(0), right: Array(64).fill(0) }));
    if (url.pathname === '/__scene/event' && request.method === 'POST') {
      let body = ''; for await (const part of request) body += part;
      events.push(JSON.parse(body)); return response.end();
    }
    if (url.pathname.startsWith('/__project/')) {
      const name = decodeURIComponent(url.pathname.slice('/__project/'.length));
      if (name === 'scene.pkg') return response.end(mediaPackage);
      const bytes = mediaFixture.get(name); if (bytes) return response.end(bytes);
    }
    if (url.pathname.startsWith('/__runtime/')) {
      const name = url.pathname.slice('/__runtime/'.length);
      assert(name && !name.includes('/') && !name.includes('..'));
      return response.end(await readFile(new URL(`../${runtimeRoot}/${name}`, import.meta.url)));
    }
    response.writeHead(404); response.end('Missing owned fixture resource');
  } catch (error) { response.writeHead(500); response.end(String(error)); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let browser;
try {
  browser = await chromium.launch({ headless: true, ...(process.env.SCENE_CHROMIUM_EXECUTABLE ? { executablePath: process.env.SCENE_CHROMIUM_EXECUTABLE } : {}) });
  for (const form of ['loose', 'package']) {
    representation = form; events.length = 0;
    const page = await browser.newPage({ viewport: { width: 640, height: 360 } });
    const errors = [], diagnostics = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', value => { if (value.status() >= 400) diagnostics.push(`HTTP ${value.status()}: ${value.url()}`); });
    page.on('console', value => { diagnostics.push(value.text()); if (value.type() === 'error') errors.push(value.text()); });
    await page.goto(`http://127.0.0.1:${server.address().port}/__runtime/index.html`);
    await page.waitForFunction(() => window.__dynamicWallpaperScene && document.querySelector('canvas'));
    let nextCommand = 0;
    const command = async payload => {
      const id = String(++nextCommand) + '-' + payload.type;
      await page.evaluate(value => window.__dynamicWallpaperScene.command(value), { id, sceneID: 'owned-media', generation: 1, ...payload });
      assert(events.some(event => event.type === 'command-ack' && event.commandID === id), JSON.stringify(events));
    };
    // Native preparation also waits for ready before sending commands.
    await page.waitForFunction(() => typeof window.__mediaStats === 'function');
    await page.waitForTimeout(100);
    assert(events.some(event => event.type === 'ready'), JSON.stringify(events));
    const pixels = async () => {
      const png = await page.screenshot();
      return page.evaluate(async encoded => {
        const image = new Image(); image.src = `data:image/png;base64,${encoded}`; await image.decode();
        const canvas = document.createElement('canvas'); canvas.width = 640; canvas.height = 360;
        const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
        const at = (x, y) => Array.from(context.getImageData(x, y, 1, 1).data).slice(0, 3);
        return { status: at(100, 50), left: at(250, 130), right: at(390, 130) };
      }, png.toString('base64'));
    };
    await command({ type: 'pause' });
    assert.deepEqual((await pixels()).status, [255, 0, 0]);
    await command({ type: 'media', media: ownedMedia, mediaRevision: 1 });
    const actual = await pixels();
    assert.deepEqual(actual.status, [0, 255, 0], `${form}: real media hook metadata/timeline/state`);
    assert(actual.left[0] > 220 && actual.left[2] < 30, `${form}: actual red PNG pixel must draw before paused acknowledgement: ${JSON.stringify({actual,diagnostics,stats:await page.evaluate(()=>window.__mediaStats())})}`);
    assert(actual.right[2] > 220 && actual.right[0] < 30, `${form}: actual blue PNG pixel must draw before paused acknowledgement`);
    await command({ type: 'play' });
    for (const [index, name] of ['play', 'pause', 'playPause', 'skipNext', 'skipPrevious'].entries()) {
      await command({ type: 'pointer', kind: 'click', x: (70 + index * 120) / 640, y: 300 / 360 });
      assert(events.some(event => event.type === 'media-control' && event.command === name && event.mediaRevision === 1), `${form}: actual ${name} hook must cross the report boundary`);
    }
    await command({ type: 'pause' });
    await command({ type: 'media', media: emptyMedia, mediaRevision: 2 });
    assert.deepEqual(await pixels(), { status: [255, 0, 0], left: [0, 0, 0], right: [0, 0, 0] });
    // Delay the real platform decoder, then queue clear behind the in-flight
    // update. No acknowledgement can cross that actual decode/draw boundary.
    await page.evaluate(() => {
      const decode = globalThis.createImageBitmap.bind(globalThis);
      globalThis.createImageBitmap = async (...args) => {
        await new Promise(resolve => { window.__releaseOwnedMediaDecode = resolve; });
        return decode(...args);
      };
    });
    const loading = command({ type: 'media', media: ownedMedia, mediaRevision: 3 });
    await page.waitForFunction(() => typeof window.__releaseOwnedMediaDecode === 'function');
    const clearingID = String(++nextCommand) + '-clear-pending';
    await page.evaluate(({ id, media }) => {
      window.__ownedPendingClear = window.__dynamicWallpaperScene.command({ id, type: 'media', media, mediaRevision: 4, sceneID: 'owned-media', generation: 1 });
    }, { id: clearingID, media: emptyMedia });
    assert(!events.some(event => event.type === 'command-ack' && event.commandID === clearingID));
    await page.evaluate(() => window.__releaseOwnedMediaDecode());
    await loading; await page.evaluate(() => window.__ownedPendingClear);
    assert(events.some(event => event.type === 'command-ack' && event.commandID === clearingID));
    assert.deepEqual(await pixels(), { status: [255, 0, 0], left: [0, 0, 0], right: [0, 0, 0] });
    assert.deepEqual(errors, [], JSON.stringify(diagnostics));
    await command({ type: 'destroy' }); await page.close();
    console.log(`SCENE_MEDIA PASS representation=${form} actualHooks=1 actualPNG=1 pausedFrameAck=1 fiveControls=1 emptyClears=1 delayedDecodeClear=1 closed=1`);
  }
} finally { await browser?.close(); await new Promise(resolve => server.close(resolve)); }
