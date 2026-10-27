const documents = new WeakMap();
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', {fatal:true, ignoreBOM:true});
const whitespace = character => /[\x20\t\r\n]/.test(character ?? '!');

export function assertSourceString(value) {
  if (typeof value !== 'string' || value.includes('\0')) throw new TypeError('Expected source string without NUL');
  for (const character of value) {
    const code = character.codePointAt(0);
    if (code >= 0xd800 && code <= 0xdfff) throw new TypeError('Source must contain valid Unicode');
  }
  return value;
}

function stateOf(document) {
  const state = documents.get(document);
  if (!state) throw new TypeError('Expected an authentic resource JSON document');
  return state;
}

function parseTree(raw, mode) {
  let at = raw[0] === '\ufeff' ? 1 : 0;
  const stack = [];
  const fail = message => { throw new SyntaxError(`${message} at JSON offset ${at}`); };
  function trivia() {
    while (at < raw.length) {
      if (whitespace(raw[at])) { at++; continue; }
      if (mode !== 'jsonc' || raw[at] !== '/') return;
      if (raw[at+1] === '/') { at += 2; while (at < raw.length && !/[\r\n]/.test(raw[at])) at++; }
      else if (raw[at+1] === '*') {
        const end = raw.indexOf('*/', at+2);
        if (end < 0) fail('Unterminated JSON comment');
        at = end+2;
      } else return;
    }
  }
  function string() {
    const start = at++;
    while (at < raw.length) {
      const character = raw[at++];
      if (character === '"') {
        const value=JSON.parse(raw.slice(start,at));
        for (const decoded of value) {
          const code=decoded.codePointAt(0);
          if (code>=0xd800 && code<=0xdfff) fail('Invalid JSON Unicode string');
        }
        return {kind:'string',start,end:at,value};
      }
      if (character.charCodeAt(0) < 32) fail('Control character in JSON string');
      if (character !== '\\') continue;
      const escaped = raw[at++];
      if (escaped === 'u') {
        if (!/^[0-9a-fA-F]{4}$/.test(raw.slice(at,at+4))) fail('Invalid JSON Unicode escape');
        at += 4;
      } else if (!escaped || !'"\\/bfnrt'.includes(escaped)) fail('Invalid JSON string escape');
    }
    fail('Unterminated JSON string');
  }
  function value() {
    trivia();
    const start = at, character = raw[at];
    if (character === '"') return string();
    if (character === '{' || character === '[') {
      at++;
      const node = {kind:character === '{' ? 'object' : 'array', start};
      if (node.kind === 'object') node.members = []; else node.items = [];
      stack.push({node, state:'first'});
      return node;
    }
    const literal = /^(?:true|false|null)/.exec(raw.slice(at));
    if (literal) { at += literal[0].length; return {kind:literal[0] === 'null' ? 'null' : 'boolean',start,end:at,value:JSON.parse(literal[0])}; }
    const number = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(raw.slice(at));
    if (!number) fail('Invalid JSON token');
    at += number[0].length;
    return {kind:'number',start,end:at,value:Number(number[0])};
  }
  const root = value();
  while (stack.length) {
    const frame = stack.at(-1), node = frame.node, object = node.kind === 'object';
    trivia();
    const close = object ? '}' : ']';
    if (frame.state === 'after') {
      if (raw[at] === ',') {
        if (object) node.members.at(-1).commaAfter = at;
        at++; frame.state = 'next'; continue;
      }
      if (raw[at] !== close) fail('Expected JSON comma or closing delimiter');
    } else {
      if (raw[at] !== close) {
        frame.state = 'after';
        if (object) {
          if (raw[at] !== '"') fail('Expected JSON member name');
          const key = string(); trivia();
          if (raw[at++] !== ':') fail('Expected JSON colon');
          const member = {key:key.value,keyStart:key.start,keyEnd:key.end};
          member.value = value(); node.members.push(member);
        } else node.items.push(value());
        continue;
      }
      if (frame.state === 'next' && mode !== 'jsonc') fail('Trailing JSON comma');
    }
    node.close = at; node.end = ++at; stack.pop();
  }
  trivia();
  if (at !== raw.length) fail('Trailing JSON token');
  return root;
}

function freezeTree(root) {
  const pending = [root];
  while (pending.length) {
    const node = pending.pop();
    if (node.members) {
      for (const member of node.members) { pending.push(member.value); Object.freeze(member); }
      Object.freeze(node.members);
    }
    if (node.items) { for (const item of node.items) pending.push(item); Object.freeze(node.items); }
    Object.freeze(node);
  }
}

/** Keep original byte ownership and every lexeme; numbers are never reserialized. */
export function parseResourceJSON(input, {mode='json'} = {}) {
  if (!(input instanceof Uint8Array)) throw new TypeError('Resource JSON bytes required');
  if (!['json','jsonc'].includes(mode)) throw new TypeError('Unsupported resource JSON mode');
  const bytes = new Uint8Array(input), raw = decoder.decode(bytes), root = parseTree(raw,mode);
  freezeTree(root);
  const document = Object.freeze({root, text:raw, mode, bytes:() => bytes.slice()});
  documents.set(document,{raw,root});
  return document;
}

export function jsonNodeAt(document, path) {
  let {root:node} = stateOf(document);
  if (!Array.isArray(path)) throw new TypeError('Expected JSON structural path');
  for (const key of path) {
    if (node?.kind === 'object' && typeof key === 'string') {
      const matches = node.members.filter(member => member.key === key);
      if (matches.length > 1) throw new Error(`Ambiguous duplicate JSON member: ${key}`);
      node = matches[0]?.value;
    } else if (node?.kind === 'array' && Number.isSafeInteger(key) && key >= 0) node = node.items[key];
    else if (node === undefined) return undefined;
    else throw new Error('Invalid JSON structural path');
  }
  return node;
}

function pathOf(link) {
  const path = [];
  for (let item = link; item; item = item.parent) path.push(item.key);
  return path.reverse();
}

/** Linked traversal paths keep deeply nested discovery linear until a match is emitted. */
export function jsonMembers(document, name) {
  const {root} = stateOf(document), result = [], pending = [{node:root,path:null,ambiguous:false}];
  while (pending.length) {
    const {node,path,ambiguous} = pending.pop();
    if (node.kind === 'object') {
      const counts = new Map();
      for (const member of node.members) counts.set(member.key,(counts.get(member.key) ?? 0)+1);
      for (let index=node.members.length-1; index>=0; index--) {
        const member=node.members[index], child={parent:path,key:member.key}, duplicate=ambiguous || counts.get(member.key)>1;
        if (member.key === name) result.push({path:pathOf(child),node:member.value,ambiguous:duplicate});
        pending.push({node:member.value,path:child,ambiguous:duplicate});
      }
    } else if (node.kind === 'array') {
      for (let index=node.items.length-1; index>=0; index--) pending.push({node:node.items[index],path:{parent:path,key:index},ambiguous});
    }
  }
  return result;
}

function patched(document, changes) {
  let {raw} = stateOf(document);
  for (const {start,end,text} of [...changes].sort((a,b)=>b.start-a.start)) raw = raw.slice(0,start)+text+raw.slice(end);
  return encoder.encode(raw);
}
function objectMember(document, path, key) {
  if (typeof key !== 'string') throw new TypeError('Expected JSON member key');
  const node = jsonNodeAt(document,path);
  if (node?.kind !== 'object') throw new Error('JSON member requires an object');
  const matches = node.members.filter(member=>member.key===key);
  if (matches.length > 1) throw new Error(`Ambiguous duplicate JSON member: ${key}`);
  return {node,member:matches[0]};
}
export function setJSONStringMember(document, path, key, value) {
  assertSourceString(value);
  const {node,member} = objectMember(document,path,key);
  if (member) {
    if (member.value.kind === 'string' && member.value.value === value) return document.bytes();
    return patched(document,[{start:member.value.start,end:member.value.end,text:JSON.stringify(value)}]);
  }
  const last = node.members.at(-1);
  const changes = [{start:node.close,end:node.close,text:JSON.stringify(key)+':'+JSON.stringify(value)+(last?.commaAfter !== undefined ? ',' : '')}];
  // Apply the member first when both insertions share the closing-brace offset.
  if (last && last.commaAfter === undefined) changes.push({start:last.value.end,end:last.value.end,text:','});
  return patched(document,changes);
}
export function removeJSONMember(document, path, key) {
  const {node,member} = objectMember(document,path,key);
  if (!member) return document.bytes();
  const changes = [{start:member.keyStart,end:member.value.end,text:''}];
  const comma = member.commaAfter ?? node.members[node.members.indexOf(member)-1]?.commaAfter;
  if (comma !== undefined) changes.push({start:comma,end:comma+1,text:''});
  return patched(document,changes);
}
export function replaceJSONValue(document, path, replacement) {
  if (typeof replacement !== 'string') throw new TypeError('Expected JSON replacement text');
  stateOf(document); assertSourceString(replacement);
  parseResourceJSON(encoder.encode(replacement),{mode:document.mode});
  const node = jsonNodeAt(document,path);
  if (!node) throw new Error('Missing JSON structural path');
  return patched(document,[{start:node.start,end:node.end,text:replacement}]);
}
