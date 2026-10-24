import { test } from 'node:test';
import assert from 'node:assert/strict';
const base = new URL('../Sources/WallpaperApp/Resources/SceneRuntime/', import.meta.url);
const load = name => import(new URL(name, base));
const config = { version: 1, sceneID: 'fixture', generation: 1, project: { representation: 'loose', entryPath: 'scene.json' }, viewport: { width: 640, height: 360 }, fps: 30, fit: 'cover', volume: 1, muted: true };

test('runtime configuration validates project form, identity and bounded numeric controls', async () => {
  const { validateConfig } = await load('scene-protocol.mjs');
  assert.deepEqual(validateConfig(config), config);
  for (const patch of [{ generation: 0 }, { fps: NaN }, { volume: 2 }, { fit: 'bogus' }, { project: { representation: 'web', entryPath: 'index.html' } }, { project: { representation: 'loose', entryPath: '../scene.json' } }]) {
    assert.throws(() => validateConfig({ ...config, ...patch }));
  }
});

test('commands reject stale identity, unknown keys and invalid pointer/control payloads', async () => {
  const { validateCommand } = await load('scene-protocol.mjs');
  for (const command of [{ id: '1', type: 'play' }, { id: '1', type: 'pause', sceneID: 'fixture', generation: 1 }, { id: '1', type: 'pointer', kind: 'move', x: .5, y: .25 }, { id: '1', type: 'pointer', kind: 'leave' }, { id: '1', type: 'volume', volume: .2, muted: false }]) assert.equal(validateCommand(command, config), command);
  for (const command of [{ id: '1', type: 'play', generation: 2 }, { id: '1', type: 'play', sceneID: 'other' }, { id: '1', type: 'play', code: '1' }, { id: '1', type: 'pointer', kind: 'move', x: -1, y: 0 }, { id: '1', type: 'volume', volume: 3, muted: false }, { id: '1', type: 'eval' }]) assert.throws(() => validateCommand(command, config));
});

test('project source uses the selected entry without package fallback and caches successful reads', async () => {
  const { createProjectSource } = await load('scene-source.mjs');
  const calls = [];
  const request = async (url, options) => { calls.push([url, options]); return new Response(url.endsWith('project.json') ? JSON.stringify({ type: 'scene', file: 'other.json' }) : new Uint8Array([1, 2, 3])); };
  const source = createProjectSource(config.project, { fetch: request, origin: 'https://fixture.test' });
  assert.equal((await source.project()).file, 'scene.json');
  const dir = await source.sceneDir();
  assert.equal(dir.entry, 'scene.json');
  assert.deepEqual(await dir.read('textures/a b.tex'), new Uint8Array([1, 2, 3]));
  await dir.read('textures/a b.tex');
  assert.equal(calls.filter(([url]) => url.endsWith('a%20b.tex')).length, 1);
  await assert.rejects(source.scenePkg(), /loose/);
});

test('source rejects traversal/external paths, exposes denied resources and preserves aborts', async () => {
  const { createProjectSource } = await load('scene-source.mjs');
  const errors = [];
  let status = 404;
  const source = createProjectSource(config.project, { origin: 'https://fixture.test', fetch: async () => new Response('', { status }), onError: error => errors.push(error.message) });
  const dir = await source.sceneDir();
  for (const path of ['../secret', '/absolute', 'https://evil/x', 'a/../../secret', 'a\\x', 'a/%2e%2e/x']) await assert.rejects(dir.read(path));
  assert.equal(await dir.read('missing.tex'), null);
  status = 403;
  await assert.rejects(dir.read('denied.tex'), /403/);
  assert.ok(errors.some(message => message.includes('403')));
  const controller = new AbortController(); controller.abort();
  await assert.rejects(dir.read('missing.tex', controller.signal), { name: 'AbortError' });
  source.dispose();
  await assert.rejects(dir.read('after-close.tex'), { name: 'AbortError' });
});

test('package source reads exact validated package path and validates metadata before engine consumption', async () => {
  const { createProjectSource } = await load('scene-source.mjs');
  const calls = [];
  const source = createProjectSource({ representation: 'package', entryPath: 'nested/custom.pkg' }, { origin: 'https://fixture.test', fetch: async url => { calls.push(url); return new Response(url.endsWith('project.json') ? '{"type":"scene","file":"scene.json"}' : new Uint8Array([4, 5])); } });
  assert.equal(await source.sceneDir(), null);
  assert.deepEqual(await source.scenePkg(), new Uint8Array([4, 5]));
  assert.equal((await source.project()).file, 'nested/custom.pkg');
  assert.ok(calls.includes('https://fixture.test/__project/nested/custom.pkg'));
  const invalid = createProjectSource(config.project, { origin: 'https://fixture.test', fetch: async () => new Response('{"type":"application"}') });
  await assert.rejects(invalid.project(), /scene/);
});

test('runtime publishes engine first-frame readiness, preserves pause and emits ordered acknowledgements', async () => {
  const { startSceneRuntime } = await load('scene-runtime.mjs');
  let finishLoad;
  const events = [], calls = [];
  const instance = {
    load: () => new Promise(resolve => { finishLoad = resolve; }),
    pause: () => calls.push('pause'), resume: () => calls.push('resume'),
    setVolume: value => calls.push(['volume', value]), setFit: value => calls.push(['fit', value]),
    setFps: value => calls.push(['fps', value]), pushPointer: (...args) => calls.push(['pointer', ...args]),
    pointerLeave: () => calls.push('leave'), destroy: value => calls.push(['destroy', value]),
  };
  const runtime = startSceneRuntime(config, { element: {}, sourceOptions: { origin: 'https://fixture.test' }, report: async value => events.push(value), createScene: (_element, options) => {
    assert.equal(options.volume, 0); assert.equal(options.autoQuality, false); assert.equal(options.media, null);
    assert.ok([...options.audio.snapshot().left].every(value => value === 0));
    return instance;
  } });
  assert.deepEqual(events, []);
  finishLoad(); await runtime.ready;
  assert.deepEqual(events[0], { type: 'ready', frame: 1, sceneID: 'fixture', generation: 1 });
  for (const [index, payload] of [{ type: 'pause' }, { type: 'volume', volume: .4, muted: false }, { type: 'play' }, { type: 'pointer', kind: 'leave', x: 0, y: 0 }].entries()) await runtime.command({ ...payload, id: String(index), sceneID: config.sceneID, generation: config.generation });
  assert.deepEqual(calls, ['pause', ['volume', .4], 'resume', 'leave']);
  assert.deepEqual(events.slice(1).map(value => value.commandID), ['0', '1', '2', '3']);
  runtime.destroy(); runtime.destroy();
  assert.deepEqual(calls.at(-1), ['destroy', { releasePkgCache: true }]);
  assert.equal(calls.filter(value => Array.isArray(value) && value[0] === 'destroy').length, 1);
});

test('destroy during preparation never publishes ready and stale commands visibly fail', async () => {
  const { startSceneRuntime } = await load('scene-runtime.mjs');
  const events = []; let finishLoad, destroyCount = 0;
  const runtime = startSceneRuntime(config, { element: {}, sourceOptions: { origin: 'https://fixture.test' }, report: async value => events.push(value), createScene: () => ({ load: () => new Promise(resolve => { finishLoad = resolve; }), destroy: () => destroyCount++ }) });
  runtime.destroy(); finishLoad();
  await assert.rejects(runtime.ready, /destroyed/);
  assert.equal(events.length, 0); assert.equal(destroyCount, 1);
});

test('paused clicks and stale commands report an explicit failure without an acknowledgement', async () => {
  const { startSceneRuntime } = await load('scene-runtime.mjs');
  const original = console.error; console.error = () => {};
  try {
    for (const payload of [{ type: 'pointer', kind: 'click', x: .5, y: .5 }, { type: 'play', generation: 2 }]) {
      const events = [];
      const runtime = startSceneRuntime(config, { element: {}, sourceOptions: { origin: 'https://fixture.test' }, report: async event => events.push(event), createScene: () => ({ paused: true, load: async () => {}, destroy: () => {} }) });
      await runtime.ready;
      await runtime.command({ id: 'failure', sceneID: config.sceneID, generation: 1, ...payload });
      assert.equal(events.filter(event => event.type === 'error').length, 1);
      assert.equal(events.filter(event => event.type === 'command-ack').length, 0);
      assert.match(events.at(-1).message, /paused|Stale/);
    }
  } finally { console.error = original; }
});
