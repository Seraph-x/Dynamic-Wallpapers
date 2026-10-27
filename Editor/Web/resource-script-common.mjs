export async function resourceDigest(bytes) {
  if (!(bytes instanceof Uint8Array)) throw new TypeError('Resource bytes required');
  const digest = await crypto.subtle.digest('SHA-256',new Uint8Array(bytes));
  return [...new Uint8Array(digest)].map(value=>value.toString(16).padStart(2,'0')).join('');
}

export function resourceOverride(snapshot,path) {
  const overrides=snapshot.resourceOverrides;
  return overrides&&Object.hasOwn(overrides,path)?overrides[path]:undefined;
}

export function equivalentSnapshot(left,right) {
  const pending=[[left,right]],seen=new WeakMap();
  while(pending.length) {
    const [a,b]=pending.pop();
    if(Object.is(a,b))continue;
    if(!a||!b||typeof a!=='object'||typeof b!=='object'||Array.isArray(a)!==Array.isArray(b))return false;
    if(Array.isArray(a)&&a.length!==b.length)return false;
    const keys=Object.keys(a);
    if(keys.length!==Object.keys(b).length||keys.some(key=>!Object.hasOwn(b,key)))return false;
    if(seen.get(a)?.has(b))continue;
    if(!seen.has(a))seen.set(a,new WeakSet());
    seen.get(a).add(b);
    for(const key of keys)pending.push([a[key],b[key]]);
  }
  return true;
}

export function freezeData(value) {
  const pending=[value],seen=new WeakSet();
  while(pending.length) {
    const item=pending.pop();
    if(!item||typeof item!=='object'||seen.has(item))continue;
    seen.add(item);
    for(const child of Object.values(item))pending.push(child);
    Object.freeze(item);
  }
  return value;
}
