import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMediaSource } from './scene-media-test-input.mjs';
const base = new URL('../Sources/WallpaperApp/Resources/SceneRuntime/', import.meta.url);
const load = name => import(new URL(name, base));
const config = { version: 1, sceneID: 'fixture', generation: 1, project: { representation: 'loose', entryPath: 'scene.json' }, viewport: { width: 640, height: 360 }, fps: 30, fit: 'cover', volume: 1, muted: true };
async function waitForDispatch(read) {
  const deadline = performance.now() + 1000;
  while (!read() && performance.now() < deadline) await new Promise(resolve => setImmediate(resolve));
  assert(read(), 'property update must reach the renderer');
}

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

test('property commands permit only data scalars and reject stale identity and extra fields', async () => {
  const { validateCommand } = await load('scene-protocol.mjs');
  const command = { id: 'properties', type: 'properties', properties: { enabled: true, amount: .5, caption: '' } };
  assert.equal(validateCommand(command, config), command);
  for (const patch of [{ properties: null }, { properties: [] }, { properties: { x: {} } }, { properties: { x: NaN } }, { generation: 2 }, { sceneID: 'other' }, { execute: 'code' }]) assert.throws(() => validateCommand({ ...command, ...patch }, config));
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
  const runtime = startSceneRuntime(config, { createMediaSource, element: {}, sourceOptions: { origin: 'https://fixture.test' }, report: async value => events.push(value), createScene: (_element, options) => {
    assert.equal(options.volume, 0); assert.equal(options.autoQuality, false); assert.equal(options.media.snapshot.hasMedia, false);
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
  const runtime = startSceneRuntime(config, { createMediaSource, element: {}, sourceOptions: { origin: 'https://fixture.test' }, report: async value => events.push(value), createScene: () => ({ load: () => new Promise(resolve => { finishLoad = resolve; }), destroy: () => destroyCount++ }) });
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
      const runtime = startSceneRuntime(config, { createMediaSource, element: {}, sourceOptions: { origin: 'https://fixture.test' }, report: async event => events.push(event), createScene: () => ({ paused: true, load: async () => {}, destroy: () => {} }) });
      await runtime.ready;
      await runtime.command({ id: 'failure', sceneID: config.sceneID, generation: 1, ...payload });
      assert.equal(events.filter(event => event.type === 'error').length, 1);
      assert.equal(events.filter(event => event.type === 'command-ack').length, 0);
      assert.match(events.at(-1).message, /paused|Stale/);
    }
  } finally { console.error = original; }
});

test('properties validate captured metadata, await renderer acknowledgement and keep command order', async () => {
  const { startSceneRuntime } = await load('scene-runtime.mjs');
  const events = [], calls = [];
  let finishUpdate, reads = 0, paused = true;
  const runtime = startSceneRuntime(config, {
    createMediaSource,
    element: {}, report: async value => events.push(value),
    sourceOptions: { origin: 'https://fixture.test', fetch: async () => { reads++; return new Response(JSON.stringify({ type: 'scene', general: { properties: { amount: { type: 'slider', value: .25, min: 0, max: 1 } } } })); } },
    createScene: () => ({
      load: async () => {}, get paused() { return paused; },
      setProperties: patch => { calls.push({ ...patch }); return new Promise(resolve => { finishUpdate = resolve; }); },
      resume: () => { paused = false; calls.push('resume'); }, destroy: () => calls.push('destroy'),
    }),
  });
  await runtime.ready;
  const update = runtime.command({ id: 'p', type: 'properties', properties: { amount: .7 } });
  const play = runtime.command({ id: 'play', type: 'play' });
  await waitForDispatch(() => finishUpdate);
  assert.equal(paused, true); assert.deepEqual(calls, [{ amount: .7 }]);
  assert.equal(events.filter(event => event.type === 'command-ack').length, 0);
  finishUpdate(); await update; await play;
  assert.deepEqual(events.filter(event => event.type === 'command-ack').map(event => event.commandID), ['p', 'play']);
  assert.deepEqual(calls, [{ amount: .7 }, 'resume']); assert.equal(reads, 1);
  const next = runtime.command({ id: 'p2', type: 'properties', properties: { amount: .2 } });
  await new Promise(resolve => setImmediate(resolve)); finishUpdate(); await next;
  assert.equal(reads, 1); runtime.destroy();
});

test('an invalid property patch applies nothing and exposes error without a successful acknowledgement', async () => {
  const { startSceneRuntime } = await load('scene-runtime.mjs');
  const original = console.error; console.error = () => {};
  try {
    for (const properties of [{ enabled: false, amount: 5 }, { missing: 1 }, { legacy: 2 }]) {
      const events = [], calls = [];
      const runtime = startSceneRuntime(config, {
        createMediaSource,
        element: {}, report: async event => events.push(event),
        sourceOptions: { origin: 'https://fixture.test', fetch: async () => new Response(JSON.stringify({ type: 'scene', preset: { legacy: 1 }, general: { properties: { enabled: { type: 'bool', value: true }, amount: { type: 'slider', value: .5, max: 1 } } } })) },
        createScene: () => ({ load: async () => {}, setProperties: value => calls.push(value), destroy: () => {} }),
      });
      await runtime.ready; await runtime.command({ id: 'invalid', type: 'properties', properties });
      assert.deepEqual(calls, []); assert.equal(events.filter(event => event.type === 'error').length, 1);
      assert.equal(events.filter(event => event.type === 'command-ack').length, 0);
    }
  } finally { console.error = original; }
});

test('property renderer rejection stays visible and destroy during await never acknowledges success', async () => {
  const { startSceneRuntime } = await load('scene-runtime.mjs');
  const original = console.error; console.error = () => {};
  try {
    for (const disposed of [false, true]) {
      const events = []; let finish, reject;
      const runtime = startSceneRuntime(config, {
        createMediaSource,
        element: {}, report: async event => events.push(event),
        sourceOptions: { origin: 'https://fixture.test', fetch: async () => new Response('{"type":"scene","general":{"properties":{"enabled":{"type":"bool","value":true}}}}') },
        createScene: () => ({ load: async () => {}, setProperties: () => new Promise((resolve, fail) => { finish = resolve; reject = fail; }), destroy: () => {} }),
      });
      await runtime.ready;
      const update = runtime.command({ id: 'p', type: 'properties', properties: { enabled: false } });
      await waitForDispatch(() => finish);
      if (disposed) { runtime.destroy(); finish(); } else reject(new Error('actual renderer rejected update'));
      await update;
      assert.equal(events.filter(event => event.type === 'command-ack').length, 0);
      if (!disposed) assert.match(events.find(event => event.type === 'error').message, /renderer rejected/);
    }
  } finally { console.error = original; }
});

test('media commands bind identity and revision and acknowledge only the actual ordered frame', async () => {
  const { validateCommand } = await load('scene-protocol.mjs');
  const { startSceneRuntime } = await load('scene-runtime.mjs');
  const empty = { hasMedia: false, state: 0, title: '', artist: '', album: '', albumArtist: '', position: 0, duration: 0, thumbnail: null };
  const current = { ...empty, hasMedia: true, state: 1, title: '实际标题', position: 2.5, duration: 12 };
  const payload = { id: 'm', type: 'media', media: current, mediaRevision: 1, sceneID: 'fixture', generation: 1 };
  assert.equal(validateCommand(payload, config), payload);
  for (const patch of [{ sceneID: 'other' }, { generation: 2 }, { mediaRevision: 0 }, { media: null }, { run: 'anything' }]) {
    assert.throws(() => validateCommand({ ...payload, ...patch }, config));
  }
  const events = [], frames = []; let source;
  const runtime = startSceneRuntime(config, {
    createMediaSource, element: {}, sourceOptions: { origin: 'https://fixture.test' }, report: async event => events.push(event),
    createScene: (_element, options) => {
      source = options.media;
      return { load: async () => {}, destroy: () => {}, setMedia: value => {
        assert.equal(value, source);
        return new Promise(resolve => frames.push({ snapshot: { ...value.snapshot }, finish: resolve }));
      } };
    },
  });
  await runtime.ready;
  const first = runtime.command(payload);
  const clear = runtime.command({ ...payload, id: 'clear', media: empty, mediaRevision: 2 });
  await waitForDispatch(() => frames.length === 1);
  assert.equal(frames[0].snapshot.title, current.title);
  assert.equal(events.filter(event => event.type === 'command-ack').length, 0);
  frames[0].finish(); await first;
  await waitForDispatch(() => frames.length === 2);
  assert.equal(frames[1].snapshot.hasMedia, false);
  frames[1].finish(); await clear;
  assert.deepEqual(events.filter(event => event.type === 'command-ack').map(event => event.commandID), ['m', 'clear']);
  runtime.destroy();
  assert.throws(() => source.play(), /disposed/);
});
