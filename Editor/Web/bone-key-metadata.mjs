const MEMBER='dynamicWallpaperBoneKeys';
const space=(raw,at)=>{while(/[\x20\t\r\n]/.test(raw[at]??'!'))at++;return at;};
function stringEnd(raw,start) {
 let at=start+1;
 while(at<raw.length){if(raw[at]==='"')return at+1;if(raw[at]==='\\')at++;at++;}
 throw new Error('Unreadable bone key metadata JSON string');
}
function valueEnd(raw,start) {
 if(raw[start]==='"')return stringEnd(raw,start);
 if(raw[start]!=='{'&&raw[start]!=='['){let at=start;while(at<raw.length&&!/[\x20\t\r\n,}\]]/.test(raw[at]))at++;return at;}
 let depth=0,at=start;
 do {
  const character=raw[at];if(character==='"'){at=stringEnd(raw,at);continue;}
  if(character==='{'||character==='[')depth++;
  if(character==='}'||character===']')depth--;
  at++;
 }while(depth&&at<raw.length);
 return at;
}
/** Parse structure while retaining every original value lexeme, including duplicates. */
function object(raw) {
 const value=JSON.parse(raw);
 if(!value||typeof value!=='object'||Array.isArray(value))throw new Error('Bone key metadata must be a JSON object');
 const members=[];let at=space(raw,space(raw,0)+1),comma;
 while(raw[at]!=='}'){
  const keyStart=at,keyEnd=stringEnd(raw,at),key=JSON.parse(raw.slice(at,keyEnd));
  const start=space(raw,space(raw,keyEnd)+1),end=valueEnd(raw,start);
  members.push({key,keyStart,start,end,comma,raw:raw.slice(start,end)});
  at=space(raw,end);if(raw[at]===','){comma=at;at=space(raw,at+1);}
 }
 return {raw,members,close:at};
}
function known(node,key) {
 const members=node.members.filter(member=>member.key===key);
 if(members.length>1)throw new Error(`Duplicate bone key metadata ${key} field`);
 return members[0];
}
function patch(node,key,replacement) {
 const member=known(node,key),raw=node.raw;
 if(member){
  if(replacement!==null)return raw.slice(0,member.start)+replacement+raw.slice(member.end);
  const index=node.members.indexOf(member),next=node.members[index+1];
  const start=index?member.comma:member.keyStart,end=!index&&next?next.keyStart:member.end;
  return raw.slice(0,start)+raw.slice(end);
 }
 if(replacement===null)return raw;
 const previous=node.members.at(-1),at=previous?.end??node.close;
 return raw.slice(0,at)+(previous?',':'')+JSON.stringify(key)+':'+replacement+raw.slice(at);
}
function record(raw) {
 const node=object(raw),count=known(node,'frameCount'),indices=known(node,'keys');
 const frameCount=count&&JSON.parse(count.raw),keys=indices&&JSON.parse(indices.raw);
 if(!Number.isInteger(frameCount)||frameCount<1||frameCount>0xffffffff)throw new Error('Invalid bone key metadata frameCount');
 if(!Array.isArray(keys)||keys.length<2||keys[0]!==0||keys.at(-1)!==frameCount||keys.some((frame,i)=>!Number.isInteger(frame)||frame<0||frame>frameCount||(i&&frame<=keys[i-1])))throw new Error('Invalid bone key metadata keys or endpoint anchors');
 return {node,frameCount,keys};
}
export function readBoneKeyMetadata(raw) {
 try {
  if(typeof raw!=='string')throw new Error('Unreadable bone key metadata');
  const root=object(raw.trim()?raw:'{}'),owned=known(root,MEMBER);
  if(!owned)return {kind:'unmanaged',root,records:new Map()};
  const namespace=object(owned.raw),version=known(namespace,'version'),clipsMember=known(namespace,'clips');
  if(!version||JSON.parse(version.raw)!==1)throw new Error('Unsupported bone key metadata version');
  if(!clipsMember)throw new Error('Missing bone key metadata clips');
  const clips=object(clipsMember.raw),records=new Map();
  for(const member of clips.members){
   if(!/^(0|[1-9]\d*)$/.test(member.key)||Number(member.key)>0xffffffff)throw new Error('Invalid bone key metadata clip ID');
   if(records.has(member.key))throw new Error('Duplicate bone key metadata clip ID');
   records.set(member.key,record(member.raw));
  }
  return {kind:'recognized',root,namespace,clips,records};
 } catch(error){return {kind:'unsupported',reason:error.message};}
}
function patchRecord(state,id,replacement) {
 const clips=state.clips?patch(state.clips,String(id),replacement):'{'+JSON.stringify(String(id))+':'+replacement+'}';
 const namespace=state.namespace?patch(state.namespace,'clips',clips):'{"version":1,"clips":'+clips+'}';
 return patch(state.root,MEMBER,namespace);
}
/** Modify only the selected record's owned spans; unknown fields remain byte exact. */
export function patchBoneKeyRecord(raw,id,values) {
 const state=readBoneKeyMetadata(raw);
 if(state.kind==='unsupported')throw new Error(state.reason);
 const previous=state.records.get(String(id));
 if(values===null){if(!previous)return raw;return patchRecord(state,id,null);}
 let next=previous?.node??object('{}');
 if(previous?.frameCount!==values.frameCount)next=object(patch(next,'frameCount',String(values.frameCount)));
 const sameKeys=previous&&previous.keys.length===values.keys.length&&previous.keys.every((frame,i)=>frame===values.keys[i]);
 return patchRecord(state,id,sameKeys?next.raw:patch(next,'keys',JSON.stringify(values.keys)));
}
/** Ordinary clip operations deliberately preserve unsupported/future metadata. */
export function syncBoneKeyClips(bones,{type,id,sourceID}) {
 for(const bone of bones){
  const state=readBoneKeyMetadata(bone.meta);
  if(state.kind!=='recognized')continue;
  const source=state.records.get(String(sourceID));
  if(type==='duplicate'&&source)bone.meta=patchRecord(state,id,source.node.raw);
  else if(state.records.has(String(id)))bone.meta=patchRecord(state,id,null);
 }
}
