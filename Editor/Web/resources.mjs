import { safePath } from './document.mjs';

export const resourceVersion = value => {
  if (typeof value !== 'string' || !/^[a-f0-9]{64}$/.test(value)) throw new Error('Invalid resource version');
  return value;
};
export function decodeResource(data) {
  if (typeof data !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(data)) throw new Error('Invalid resource base64');
  const bytes = Uint8Array.from(atob(data),character => character.charCodeAt(0));
  if (encodeResource(bytes) !== data) throw new Error('Invalid resource base64');
  return bytes;
}
export function encodeResource(bytes) {
  let result = '';
  for (let offset = 0; offset < bytes.length; offset += 32768) result += String.fromCharCode(...bytes.subarray(offset,offset+32768));
  return btoa(result);
}
async function digest(bytes) {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(value => value.toString(16).padStart(2,'0')).join('');
}
export function createResourceClient(report) {
  const pending = new Map(); let closed = false;
  function request(payload) {
    if (closed) return Promise.reject(new Error('Editor resources closed'));
    const id = crypto.randomUUID();
    return new Promise((resolve,reject) => {
      pending.set(id,{resolve,reject});
      Promise.resolve().then(() => { if (pending.has(id)) return report({type:'resource',id,...payload}); }).catch(error => {
        pending.delete(id); reject(error);
      });
    });
  }
  return {
    async paths() {
      const result=await request({action:'list'});
      if(!Array.isArray(result.paths))throw new Error('Invalid resource inventory');
      return result.paths.map(safePath);
    },
    async stage(bytes) {
      if (!(bytes instanceof Uint8Array)) throw new Error('Resource bytes required');
      const copy = bytes.slice(), expected = await digest(copy), result = await request({action:'stage',data:encodeResource(copy)});
      if (resourceVersion(result.version) !== expected) throw new Error('Staged resource is corrupt');
      return expected;
    },
    async read(version) {
      resourceVersion(version);
      const result = await request({action:'read',version}), bytes = decodeResource(result.data);
      if (await digest(bytes) !== version) throw new Error('Read resource is corrupt');
      return bytes;
    },
    reply({requestID,result}) {
      const request = pending.get(requestID);
      if (!request) throw new Error('Unsolicited resource reply');
      pending.delete(requestID);
      if (!result || typeof result !== 'object' || Array.isArray(result)) request.reject(new Error('Invalid resource reply'));
      else if (Object.hasOwn(result,'error')) request.reject(new Error(String(result.error)));
      else request.resolve(result);
    },
    dispose() { closed = true; for (const request of pending.values()) request.reject(new Error('Editor resources closed')); pending.clear(); },
  };
}
export function resourceReader(snapshot,readOriginal,readVersion) {
  const overrides = {...snapshot.resourceOverrides}, cache = new Map();
  return async path => {
    safePath(path);
    if (!Object.hasOwn(overrides,path)) return readOriginal(path);
    const version = resourceVersion(overrides[path]);
    if (!cache.has(version)) cache.set(version,Promise.resolve().then(() => readVersion(version)));
    return (await cache.get(version)).slice();
  };
}
