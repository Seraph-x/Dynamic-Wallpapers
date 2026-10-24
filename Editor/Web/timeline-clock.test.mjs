import test from 'node:test';
import assert from 'node:assert/strict';
import { TimelineClock } from './timeline-clock.mjs';
test('clock uses the engine time, serializes seeks and keeps playback state separate',async()=>{
  let time=0,playing=true;const sought=[];
  const editor={get controls(){return {get time(){return time;}};},get playing(){return playing;},setPlaying(value){playing=value;},async seek(value){await Promise.resolve();time=value;sought.push(value);},frozen:false};
  const clock=new TimelineClock(editor);
  await Promise.all([clock.seek(.5),clock.seek(1)]);assert.equal(time,1);assert.deepEqual(sought,[.5,1]);assert.equal(playing,false);
  await clock.step(-1,30);assert(Math.abs(time-29/30)<1e-12);
  clock.range({start:.25,end:.75,loop:true});playing=true;time=.9;await clock.tick();assert(Math.abs(time-.4)<1e-12);assert.equal(playing,true);
  editor.frozen=true;time=1;await clock.tick();assert.equal(time,1);
  assert.throws(()=>clock.range({start:1,end:.5,loop:true}));await assert.rejects(clock.seek(-1));
});
test('rapid relative frame steps each use the preceding completed engine time',async()=>{
  let time=0;const editor={controls:{get time(){return time;}},setPlaying(){},async seek(value){await Promise.resolve();time=value;}};
  const clock=new TimelineClock(editor);
  await Promise.all([clock.step(1,30),clock.step(1,30),clock.step(1,30)]);
  assert(Math.abs(time-.1)<1e-12,'Repeated frame steps collapsed onto one target');
});
