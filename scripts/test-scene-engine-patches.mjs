import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import * as patches from './scene-engine-patches.mjs';
import {runInNewContext} from 'node:vm';

const upstream=await readFile(new URL('./scene-runtime-build/node_modules/webwallgl/webwallgl.mjs',import.meta.url),'utf8');
const hash=value=>createHash('sha256').update(value).digest('hex');
test('patches leave the verified original intact and produce deterministic recorded output',()=>{
 assert.equal(hash(upstream),'f838e70347df8205edca5f3fc04dbb7c56b31738b5785b27038d912d5c45a1bc');
 const result=patches.patchSceneEngine(upstream),again=patches.patchSceneEngine(upstream);
 assert.equal(result.source,again.source);assert.notEqual(result.source,upstream);
 assert(result.patches.every(patch=>patch.id&&patch.reason));assert.equal(new Set(result.patches.map(patch=>patch.id)).size,result.patches.length);
 assert.equal(hash(upstream),'f838e70347df8205edca5f3fc04dbb7c56b31738b5785b27038d912d5c45a1bc');
});
test('missing or repeated pinned anchors fail explicitly instead of patching an unknown engine',()=>{
 assert.throws(()=>patches.patchSceneEngine(upstream.replace('const applyLiveProps = (wire) => {','const missingLiveProps = (wire) => {')),/anchor|match|upstream/i);
 assert.throws(()=>patches.patchSceneEngine(upstream+'\n'+upstream),/anchor|match|upstream/i);
});
test('explicit external media wins even when empty and another live or wallpaper source has an item',()=>{
 const source=patches.patchSceneEngine(upstream).source;
 const line=source.split('\n').find(line=>line.includes('const currentMediaDriver ='));
 const external={snapshot:{hasMedia:false}},wallpaper={snapshot:{hasMedia:true},hasCurrent:()=>true},live={snapshot:{hasMedia:true}},sim={snapshot:{hasMedia:true}};
 const context={rt:{mediaSource:external},liveMediaOverride:live,wallpaperAudio:wallpaper,simMedia:sim,hasLiveMedia:driver=>!!driver?.snapshot?.hasMedia};
 const get=runInNewContext(`${line}\ncurrentMediaDriver`,context);
 assert.equal(get(),external);
 context.liveMediaOverride=null; assert.equal(get(),external);
 context.rt.mediaSource=null; assert.equal(get(),wallpaper);
 wallpaper.hasCurrent=()=>false; assert.equal(get(),sim);
});
