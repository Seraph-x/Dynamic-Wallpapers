import test from 'node:test';
import assert from 'node:assert/strict';
import { createResourceClient, resourceReader } from './resources.mjs';
const hash = 'a12871fee210fb8619291eaea194581cbd2531e4b23759d225f6806923f63222'; // SHA-256([1,2])
test('resource RPC stages real bytes, verifies read hashes and rejects close/failure', async () => {
  const requests = [], client = createResourceClient(value => { requests.push(value); return Promise.resolve(); });
  const stage = client.stage(new Uint8Array([1,2]));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(requests[0].data,'AQI=');
  client.reply({requestID:requests[0].id,result:{version:hash}});
  assert.equal(await stage,hash);
  const read = client.read(hash); await new Promise(resolve => setImmediate(resolve));
  client.reply({requestID:requests[1].id,result:{data:'AQI='}});
  assert.deepEqual(await read,new Uint8Array([1,2]));
  const invalid = client.read(hash); await new Promise(resolve => setImmediate(resolve));
  client.reply({requestID:requests[2].id,result:{data:'AQ=='}});
  await assert.rejects(invalid,/corrupt/i);
  const failure = client.read(hash); await new Promise(resolve => setImmediate(resolve));
  client.reply({requestID:requests[3].id,result:{error:'Disk failure'}});
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
