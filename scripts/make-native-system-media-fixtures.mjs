import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { mediaFixture } from './system-media-fixture.mjs';

const [output, source] = process.argv.slice(2);
if (!output || !['music', 'spotify'].includes(source)) throw new Error('Expected isolated output and owned adapter music/spotify');
const files = new Map(mediaFixture);
const scene = JSON.parse(files.get('scene.json'));
scene.objects[0].color.script = `
let enabled=false;
export function mediaStatusChanged(event){enabled=event.enabled;}
export function update(value){
 if(!enabled)return new Vec3(1,0,0);
 const s=engine.media.snapshot;
 const neutral=[s.primaryColor,s.secondaryColor,s.tertiaryColor].every(c=>c.x===0&&c.y===0&&c.z===0)
  &&[s.textColor,s.highContrastColor].every(c=>c.x===1&&c.y===1&&c.z===1);
 const metadata=(s.title===${JSON.stringify('Owned 雪 "é🎵')}||s.title==='Owned second')
  &&s.artist==='Owned Artist'&&s.album==='Owned Album'
  &&s.albumArtist===${JSON.stringify(source === 'music' ? 'Owned Ensemble' : '')}
  &&s.position===12.5&&s.duration===180.25&&neutral;
 if(!metadata)return new Vec3(0,0,1);
 if(s.state===2)return new Vec3(1,1,0);
 if(s.state!==1)return new Vec3(0,0,1);
 return s.title==='Owned second'?new Vec3(0,1,1):new Vec3(0,1,0);
}`;
files.set('scene.json', Buffer.from(JSON.stringify(scene)));
const uint32 = value => { const result = Buffer.alloc(4); result.writeUInt32LE(value); return result; };
const text = value => { const bytes = Buffer.from(value); return Buffer.concat([uint32(bytes.length), bytes]); };
const entries = [...files].filter(([name]) => name !== 'project.json');
let offset = 0;
const pkg = Buffer.concat([text('PKGV0012'), uint32(entries.length), ...entries.flatMap(([name, bytes]) => {
  const record = [text(name), uint32(offset), uint32(bytes.length)]; offset += bytes.length; return record;
}), ...entries.map(([, bytes]) => bytes)]);
for (const form of ['loose', 'package']) {
  const root = path.join(output, form);
  await mkdir(root, { recursive: true });
  if (form === 'loose') {
    for (const [name, bytes] of files) {
      await mkdir(path.dirname(path.join(root, name)), { recursive: true });
      await writeFile(path.join(root, name), bytes, { flag: 'wx' });
    }
  } else {
    await writeFile(path.join(root, 'scene.pkg'), pkg, { flag: 'wx' });
    await writeFile(path.join(root, 'project.json'), JSON.stringify({ type: 'scene', file: 'scene.pkg' }), { flag: 'wx' });
  }
}
