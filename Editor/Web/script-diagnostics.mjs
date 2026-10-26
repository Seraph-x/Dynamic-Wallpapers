const ISSUE_FIELDS = Object.freeze(['layerId','layerName','target','phase','message','line','count']);
const EVENT_BYTE_LIMIT = 8192;
const encoder = new TextEncoder();
const positiveInteger = value => Number.isSafeInteger(value) && value > 0;

export function validateScriptIssue(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== ISSUE_FIELDS.length || ISSUE_FIELDS.some(key => !Object.hasOwn(value,key))) throw new TypeError('Invalid script issue fields');
  if (!(value.layerId === null || typeof value.layerId === 'number' && Number.isFinite(value.layerId))) throw new TypeError('Invalid script issue layerId');
  for (const field of ['layerName','target','phase','message']) if (typeof value[field] !== 'string') throw new TypeError(`Invalid script issue ${field}`);
  if (!(value.line === null || positiveInteger(value.line)) || !positiveInteger(value.count)) throw new TypeError('Invalid script issue line or count');
  return Object.freeze(Object.fromEntries(ISSUE_FIELDS.map(field => [field,value[field]])));
}

export function scriptIssueKey(issue) {
  const value = validateScriptIssue(issue);
  return JSON.stringify([value.layerId,value.target,value.phase,value.message]);
}

function validateIdentity({sceneID,generation,transferID}) {
  for (const [key,value] of Object.entries({sceneID,transferID})) if (typeof value !== 'string' || !value.length || value.length > 128 || value.includes('\0')) throw new TypeError(`Invalid script issue ${key}`);
  if (!positiveInteger(generation)) throw new TypeError('Invalid script issue generation');
}

export function encodeScriptIssueParts(issue, identity) {
  validateIdentity(identity);
  const {sceneID,generation,transferID} = identity;
  const bytes = encoder.encode(JSON.stringify(validateScriptIssue(issue)));
  // Each fragment is independently canonical base64, so native can decode
  // without carrying a partial base64 quartet between ordered fragments.
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const data = btoa(binary), parts = [];
  let offset = 0;
  while (offset < data.length) {
    const part = {type:'script-issue-part',sceneID,generation,transferID,ordinal:parts.length,final:false,data:''};
    const overhead = encoder.encode(JSON.stringify(part)).length;
    const capacity = Math.floor((EVENT_BYTE_LIMIT-overhead)/4)*4;
    if (capacity < 4) throw new RangeError('Script issue identity exceeds scene event byte budget');
    part.data = data.slice(offset,offset+capacity);
    offset += part.data.length;
    part.final = offset === data.length;
    parts.push(Object.freeze(part));
  }
  return Object.freeze(parts);
}

function randomTransferID() {
  // CEF's local HTTP project origin is not a secure context. getRandomValues
  // provides actual random identities there; randomUUID requires HTTPS.
  return [...crypto.getRandomValues(new Uint8Array(16))].map(byte=>byte.toString(16).padStart(2,'0')).join('');
}

export function observeScriptIssues({read,report,onError,sceneID,generation,requestFrame=requestAnimationFrame,cancelFrame=cancelAnimationFrame,createTransferID=randomTransferID}) {
  let stopped = false, frame;
  const sent = new Map(), abort = new AbortController();
  const stop = () => {
    if (stopped) return;
    stopped = true;
    if (frame !== undefined) cancelFrame(frame);
    frame = undefined;
    abort.abort();
  };
  async function poll() {
    frame = undefined;
    if (stopped) return;
    try {
      const records = await read();
      if (stopped) return;
      if (!Array.isArray(records)) throw new TypeError('Script issues must be an array');
      for (const record of records) {
        if (stopped) return;
        const issue = validateScriptIssue(record), key = scriptIssueKey(issue), serialized = JSON.stringify(issue);
        if (sent.get(key) === serialized) continue;
        const parts = encodeScriptIssueParts(issue,{sceneID,generation,transferID:createTransferID()});
        for (const part of parts) {
          if (stopped) return;
          await report(part,{signal:abort.signal});
        }
        if (stopped) return;
        sent.set(key,serialized);
      }
      if (!stopped) frame = requestFrame(poll);
    } catch (error) {
      if (stopped) return;
      stop();
      onError(error);
    }
  }
  frame = requestFrame(poll);
  return stop;
}
