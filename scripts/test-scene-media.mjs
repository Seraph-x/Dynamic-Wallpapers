import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createMediaSource } from './scene-media-test-input.mjs';

const moduleURL = new URL('../Sources/WallpaperApp/Resources/SceneRuntime/scene-media.mjs', import.meta.url);
const media = await import(moduleURL);
const empty = () => ({ hasMedia: false, state: 0, title: '', artist: '', album: '', albumArtist: '', position: 0, duration: 0, thumbnail: null });
const current = () => ({ ...empty(), hasMedia: true, state: 1, title: '真实 🎵\n<script>', artist: '作者', album: 'Album', position: 12.75, duration: 180.5 });
const png = `data:image/png;base64,${(await readFile(new URL('../Tests/MediaAutomationHarness/Fixtures/owned-artwork.png', import.meta.url))).toString('base64')}`;

test('media wire is strict and invalid values cannot partially replace the current item', () => {
  assert.equal(typeof media.createSceneMediaSource, 'function', 'explicit scene media source is not implemented');
  const owner = media.createSceneMediaSource({ createMediaSource, report: async () => {}, onError: assert.fail });
  owner.replace(current(), 1);
  const original = owner.source.snapshot;
  for (const value of [null, [], {}, { ...current(), title: null }, { ...current(), state: 3 },
    { ...current(), state: true }, { ...current(), position: -1 }, { ...current(), duration: NaN },
    { ...current(), thumbnail: 'https://untrusted.example/image' }, { ...current(), thumbnail: 'data:image/png;base64,aGVsbG8=' },
    { ...current(), thumbnail: `${png}\n` }, { ...current(), run: 'arbitrary' }, { ...current(), hasMedia: false }]) {
    assert.throws(() => owner.replace(value, 2));
    assert.equal(owner.source.snapshot, original, 'invalid update must leave the entire current snapshot intact');
  }
  const missing = current(); delete missing.thumbnail;
  assert.throws(() => owner.replace(missing, 2));
  for (const revision of [0, -1, NaN, true, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => owner.replace(current(), revision));
    assert.equal(owner.source.snapshot, original);
  }
});

test('actual pinned source receives complete metadata, real PNG and an explicitly empty replacement', () => {
  const owner = media.createSceneMediaSource({ createMediaSource, report: async () => {}, onError: assert.fail });
  assert.equal(owner.source.snapshot.hasMedia, false);
  owner.replace({ ...current(), thumbnail: png }, 1);
  assert.equal(owner.source.snapshot.title, current().title);
  assert.equal(owner.source.snapshot.position, 12.75);
  assert.equal(owner.source.snapshot.hasThumbnail, true);
  assert.equal(owner.source.snapshot.thumbnail, png);
  assert.equal(owner.source.snapshot.primaryColor.x, 0);
  assert.equal(owner.source.snapshot.textColor.x, 1);
  assert.equal(owner.source.snapshot.lyrics.length, 0);
  owner.source.update(999999);
  assert.equal(owner.source.snapshot.position, 12.75, 'native position must not be simulated');
  owner.replace(empty(), 2);
  for (const key of ['title', 'artist', 'album', 'albumArtist']) assert.equal(owner.source.snapshot[key], '');
  assert.equal(owner.source.snapshot.hasMedia, false);
  assert.equal(owner.source.snapshot.hasThumbnail, false);
  assert.equal(owner.source.snapshot.thumbnail, undefined);
  assert.equal(owner.source.snapshot.position, 0);
  assert.equal(owner.source.snapshot.duration, 0);
});

test('five transport controls emit only fixed data and reject empty or disposed owners', async () => {
  const events = [];
  const owner = media.createSceneMediaSource({ createMediaSource, report: async value => { events.push(value); }, onError: assert.fail });
  const commands = ['play', 'pause', 'playPause', 'skipNext', 'skipPrevious'];
  for (const command of commands) assert.throws(() => owner.source[command](), /current.*media/i);
  owner.replace(current(), 1);
  for (const command of commands) owner.source[command]();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(events, commands.map(command => ({ type: 'media-control', command, mediaRevision: 1 })));
  owner.dispose();
  assert.equal(owner.source.snapshot.hasMedia, false);
  for (const command of commands) assert.throws(() => owner.source[command](), /disposed/i);
  assert.throws(() => owner.replace(current(), 2), /disposed/i);
});

test('failed transport reporting exposes the original error without an unhandled rejection', async () => {
  const failure = new Error('native transport channel unavailable');
  const errors = [];
  const owner = media.createSceneMediaSource({ createMediaSource, report: async () => { throw failure; }, onError: error => errors.push(error) });
  owner.replace(current(), 1); owner.source.playPause();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(errors, [failure]);
});

test('queued transport cannot cross a changed native media revision or disposal', async () => {
  const events = [];
  const owner = media.createSceneMediaSource({ createMediaSource, report: async value => events.push(value), onError: assert.fail });
  owner.replace(current(), 1); owner.source.play();
  owner.replace({ ...current(), title: 'Different selected provider item' }, 2);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(events, []);
  owner.source.pause(); owner.dispose();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(events, []);
});
