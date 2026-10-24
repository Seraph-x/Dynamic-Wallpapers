import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createSpectrumSource, pollSpectrum } from '../Sources/WallpaperApp/Resources/SceneRuntime/scene-spectrum.mjs';

const config = { sceneID: 'audio', generation: 2 };
const packet = (value = 0.5) => ({ ...config, left: Array(64).fill(value), right: Array(64).fill(value / 2) });

test('spectrum validates identity, channel count, finite range and copies caller data', () => {
  const source = createSpectrumSource(config);
  assert.ok(source.snapshot().left.every(value => value === 0));
  const data = packet(); source.update(data); data.left[0] = 1;
  assert.equal(source.snapshot().left[0], 0.5);
  assert.equal(source.snapshot().right[0], 0.25);
  for (const patch of [{ generation: 1 }, { sceneID: 'other' }, { left: [0] }, { left: Array(64).fill(NaN) }, { right: Array(64).fill(2) }, { left: Array(64).fill(-1) }]) {
    assert.throws(() => source.update({ ...packet(), ...patch }));
  }
  source.clear(); assert.ok(source.snapshot().left.every(value => value === 0));
});

test('polling has one request in flight and disposal aborts without publishing', async () => {
  let finish, signal, requested = 0, published = 0;
  const stop = pollSpectrum({ update: () => published++ }, {
    fetch: async (_url, options) => { requested++; signal = options.signal; return new Promise(resolve => { finish = resolve; }); },
    onError: error => { throw error; },
  });
  await new Promise(resolve => setTimeout(resolve, 80));
  assert.equal(requested, 1);
  stop(); assert.equal(signal.aborted, true);
  finish(new Response(JSON.stringify(packet())));
  await new Promise(resolve => setTimeout(resolve, 40));
  assert.equal(published, 0); assert.equal(requested, 1);
});

test('transport and malformed payload failures are reported once and stop polling', async () => {
  for (const response of [new Response('', { status: 403 }), new Response('broken')]) {
    const errors = []; let requests = 0;
    const stop = pollSpectrum(createSpectrumSource(config), {
      fetch: async () => { requests++; return response; }, onError: error => errors.push(error),
    });
    await new Promise(resolve => setTimeout(resolve, 80)); stop();
    assert.equal(errors.length, 1); assert.equal(requests, 1);
  }
});
