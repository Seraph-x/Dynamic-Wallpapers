import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { createResourceClient, resourceReader } from './resources.mjs';
const hash = 'a12871fee210fb8619291eaea194581cbd2531e4b23759d225f6806923f63222'; // SHA-256([1,2])
test('resource RPC stages real bytes, verifies read hashes and rejects close/failure', async () => {
  const reports = new EventEmitter(), client = createResourceClient(value => { reports.emit('request',value); return Promise.resolve(); });
  async function request(operation) {
    const reported = once(reports,'request'), result = operation();
    const [sent] = await reported;
    return {result,sent};
  }
  const {result:stage,sent:staged} = await request(() => client.stage(new Uint8Array([1,2])));
  assert.equal(staged.data,'AQI=');
  client.reply({requestID:staged.id,result:{version:hash}});
  assert.equal(await stage,hash);
  const {result:read,sent:reading} = await request(() => client.read(hash));
  client.reply({requestID:reading.id,result:{data:'AQI='}});
  assert.deepEqual(await read,new Uint8Array([1,2]));
  const {result:invalid,sent:corrupt} = await request(() => client.read(hash));
  client.reply({requestID:corrupt.id,result:{data:'AQ=='}});
  await assert.rejects(invalid,/corrupt/i);
  const {result:failure,sent:failed} = await request(() => client.read(hash));
  client.reply({requestID:failed.id,result:{error:'Disk failure'}});
  await assert.rejects(failure,/Disk failure/);
  assert.throws(() => client.reply({requestID:'unknown',result:{data:''}}),/Unsolicited/);
  const pending = client.read(hash); client.dispose(); await assert.rejects(pending,/closed/);
  await assert.rejects(client.read(hash),/closed/);
});
test('resource resolution captures each snapshot and preserves unknown originals', async () => {
  const document = {resourceOverrides:{'a.bin':hash}};
  const original = async path => path === 'other.bin' ? new Uint8Array([9]) : null;
  const first = resourceReader(document,original,async version => {assert.equal(version,hash);return new Uint8Array([1,2]);});
  document.resourceOverrides['a.bin'] = 'b'.repeat(64);
  const second = resourceReader(document,original,async () => new Uint8Array([3]));
  assert.deepEqual(await first('a.bin'),new Uint8Array([1,2]));
  assert.deepEqual(await second('a.bin'),new Uint8Array([3]));
  assert.deepEqual(await first('other.bin'),new Uint8Array([9]));
  assert.equal(await first('absent'),null); await assert.rejects(first('../outside'));
});
