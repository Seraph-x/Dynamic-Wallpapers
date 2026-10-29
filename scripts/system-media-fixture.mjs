import { readFile } from 'node:fs/promises';

export const emptyMedia = { hasMedia: false, state: 0, title: '', artist: '', album: '', albumArtist: '', position: 0, duration: 0, thumbnail: null };
export const actualPNG = await readFile(new URL('../Tests/MediaAutomationHarness/Fixtures/owned-artwork.png', import.meta.url));
export const ownedMedia = { ...emptyMedia, hasMedia: true, state: 1, title: 'Owned 实际 🎵', artist: 'Owned artist',
  album: 'Owned album', albumArtist: 'Owned album artist', position: 12.75, duration: 180.5, thumbnail: `data:image/png;base64,${actualPNG.toString('base64')}` };
const commands = ['play', 'pause', 'playPause', 'skipNext', 'skipPrevious'];
const scene = {
  general: { orthogonalprojection: { width: 640, height: 360 }, clearenabled: true, clearcolor: '0 0 0', cameraparallax: false },
  objects: [
    { id: 1, name: 'Exact actual metadata or empty status', solid: true, size: '160 60', origin: '100 310 0', color: {
      value: '1 0 0', script: `let enabled=false,title='',position=0,duration=0,state=0;
export function mediaStatusChanged(e){enabled=e.enabled;}
export function mediaPropertiesChanged(e){title=e.title;}
export function mediaTimelineChanged(e){position=e.position;duration=e.duration;}
export function mediaPlaybackChanged(e){state=e.state;}
export function update(value){return !enabled ? new Vec3(1,0,0) : title===${JSON.stringify(ownedMedia.title)} && position===12.75 && duration===180.5 && state===1 ? new Vec3(0,1,0) : new Vec3(0,0,1);}`,
    } },
    { id: 2, name: 'Actual owned PNG pixels', image: 'models/cover.json', size: '160 80', origin: '320 230 0',
      instance: { usertextures: [{ name: '$mediaThumbnail' }] }, color: { value: '1 1 1', script:
        'export function init(value){thisObject.visible=false;return value;} export function mediaThumbnailChanged(e){thisObject.visible=e.hasThumbnail;}' } },
    ...commands.map((command, index) => ({ id: index + 10, name: `Actual ${command} hook`, solid: true,
      size: '80 50', origin: `${70 + index * 120} 60 0`, color: { value: '1 1 1',
        script: `export function cursorClick(event){engine.media.${command}();}` } })),
    { id: 30, name: 'Owned wallpaper audio must never substitute', sound: ['owned-wallpaper.wav'],
      soundprops: { playbackmode: 'loop', volume: 0 }, volume: { value: 0,
        script: 'export function init(value){thisObject.play();return value;}' } },
  ],
};
export const mediaFixture = new Map([
  ['project.json', Buffer.from(JSON.stringify({ type: 'scene', file: 'scene.json', title: 'Owned system media acceptance' }))],
  ['scene.json', Buffer.from(JSON.stringify(scene))],
  ['models/cover.json', Buffer.from(JSON.stringify({ material: 'materials/cover.json', width: 160, height: 80 }))],
  ['materials/cover.json', Buffer.from(JSON.stringify({ passes: [{ shader: 'generic', textures: ['util/white'] }] }))],
  ['shaders/generic.frag', Buffer.from('uniform sampler2D g_Texture0; varying vec2 v_TexCoord; void main(){gl_FragColor=texture2D(g_Texture0,v_TexCoord);}')],
]);
// Authored one-second PCM silence: actual wallpaper audio, with no audible tone.
const wav = Buffer.alloc(44 + 48000 * 2);
wav.write('RIFF', 0); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8);
wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
wav.writeUInt32LE(48000, 24); wav.writeUInt32LE(96000, 28); wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34);
wav.write('data', 36); wav.writeUInt32LE(wav.length - 44, 40);
mediaFixture.set('owned-wallpaper.wav', wav);
const uint32 = value => { const result = Buffer.alloc(4); result.writeUInt32LE(value); return result; };
const text = value => { const bytes = Buffer.from(value); return Buffer.concat([uint32(bytes.length), bytes]); };
let offset = 0;
const entries = [...mediaFixture].filter(([name]) => name !== 'project.json');
export const mediaPackage = Buffer.concat([text('PKGV0012'), uint32(entries.length), ...entries.flatMap(([name, bytes]) => {
  const record = [text(name), uint32(offset), uint32(bytes.length)]; offset += bytes.length; return record;
}), ...entries.map(([, bytes]) => bytes)]);
