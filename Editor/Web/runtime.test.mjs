import test from 'node:test';
import assert from 'node:assert/strict';
import { createEditorSource, validateEditorCommand } from './runtime.mjs';
const document = { entry: 'nested/scene.json', scene: { objects: [] }, project: { type: 'scene', file: 'scene.pkg', future: true } };
test('preview reads current scene and metadata without replacing original resources', async () => {
  const source = createEditorSource(document, async path => path === 'a.png' ? new Uint8Array([1]) : null);
  assert.equal((await source.project()).file, 'nested/scene.json');
  const dir = await source.sceneDir();
  assert.deepEqual(JSON.parse(new TextDecoder().decode(await dir.read('nested/scene.json'))), { objects: [] });
  assert.deepEqual(await dir.read('a.png'), new Uint8Array([1]));
  assert.equal(await dir.read('optional.tex'), null);
  await assert.rejects(() => dir.read('../outside')); await assert.rejects(() => source.scenePkg());
});
test('commands reject stale sessions, unknown commands and incomplete payloads', () => {
  const config = { session: 'abc', generation: 1 };
  const command = { session: 'abc', generation: 1, id: 'a', type: 'snapshot' };
  assert.doesNotThrow(() => validateEditorCommand(command, config));
  for (const patch of [{ session: 'other' }, { generation: 2 }, { type: 'exec' }, { id: '' }, { type: 'load' }, { extra: true }])
    assert.throws(() => validateEditorCommand({ ...command, ...patch }, config));
});
test('preview resolves versioned resources using the chosen snapshot', async () => {
  const value = {...document,resourceOverrides:{'a.bin':'a'.repeat(64)}};
  const source = createEditorSource(value,async () => new Uint8Array([0]),async version => {
    assert.equal(version,'a'.repeat(64)); return new Uint8Array([9]);
  });
  value.resourceOverrides['a.bin'] = 'b'.repeat(64);
  assert.deepEqual(await (await source.sceneDir()).read('a.bin'),new Uint8Array([9]));
});
