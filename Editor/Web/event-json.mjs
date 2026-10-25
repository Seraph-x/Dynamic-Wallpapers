/** Metadata is validated, but only the two authored value spans are replaced. */
function stringEnd(raw,start) {
 let at=start+1;
 while(at<raw.length){if(raw[at]==='"')return at+1;if(raw[at]==='\\')at++;at++;}
 throw new Error('Unreadable animation event JSON string');
}
const whitespace=(raw,at)=>{while(/[\x20\t\r\n]/.test(raw[at]??'!'))at++;return at;};
function valueEnd(raw,start) {
 if(raw[start]==='"')return stringEnd(raw,start);
 if(raw[start]!=='{'&&raw[start]!=='['){let at=start;while(at<raw.length&&!/[\x20\t\r\n,}\]]/.test(raw[at]))at++;return at;}
 let depth=0,at=start;
 do {
  const character=raw[at];
  if(character==='"'){at=stringEnd(raw,at);continue;}
  if(character==='{'||character==='[')depth++;
  if(character==='}'||character===']')depth--;
  at++;
 } while(depth&&at<raw.length);
 return at;
}
function knownSpans(raw) {
 if(typeof raw!=='string')throw new Error('Unreadable animation event JSON');
 try{JSON.parse(raw);}catch{throw new Error('Unreadable animation event JSON');}
 let at=whitespace(raw,0);
 if(raw[at]!=='{')throw new Error('Animation event JSON must be an object');
 const spans={};at=whitespace(raw,at+1);
 while(raw[at]!=='}'){
  const end=stringEnd(raw,at),key=JSON.parse(raw.slice(at,end));
  at=whitespace(raw,whitespace(raw,end)+1);
  const start=at;at=valueEnd(raw,at);
  if(key==='frame'||key==='name'){
   if(Object.hasOwn(spans,key))throw new Error(`Duplicate animation event ${key} key`);
   spans[key]={start,end:at,value:JSON.parse(raw.slice(start,at))};
  }
  at=whitespace(raw,at);if(raw[at]===',')at=whitespace(raw,at+1);
 }
 return spans;
}
export function validateEventName(value) {
 if(typeof value!=='string'||value.includes('\0'))throw new Error('Animation event name must be a valid Unicode string without NUL');
 for(const character of value){const code=character.codePointAt(0);if(code>=0xd800&&code<=0xdfff)throw new Error('Animation event name must contain valid Unicode');}
 return value;
}
export function validateEventFrame(value,frameCount) {
 if(!Number.isInteger(value)||value<0||value>frameCount)throw new Error('Animation event frame must be an integer in 0..frameCount');
 return value;
}
export function readEventMetadata(event,clip) {
 const spans=knownSpans(event.json),frame=validateEventFrame(spans.frame?.value,clip.frameCount),name=validateEventName(spans.name?.value);
 if(event.time!==Math.fround(frame/clip.fps))throw new Error('Animation event time is inconsistent with its frame');
 return {frame,name};
}
export function patchEventMetadata(raw,changes) {
 const spans=knownSpans(raw),patches=[];
 for(const key of ['frame','name'])if(Object.hasOwn(changes,key)){
  const span=spans[key];if(!span)throw new Error(`Animation event ${key} metadata is missing`);
  if(key==='name')validateEventName(changes[key]);
  else if(!Number.isInteger(changes[key])||changes[key]<0)throw new Error('Invalid animation event frame');
  if(changes[key]!==span.value)patches.push({...span,replacement:JSON.stringify(changes[key])});
 }
 for(const {start,end,replacement} of patches.sort((a,b)=>b.start-a.start))raw=raw.slice(0,start)+replacement+raw.slice(end);
 return raw;
}
