import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { mediaFixture, mediaPackage, emptyMedia, ownedMedia } from './system-media-fixture.mjs';
const output = process.argv[2];
if (!output) throw new Error('An isolated output directory is required');
for (const form of ['loose', 'package']) {
  const root = path.join(output, form);
  await mkdir(root, { recursive: true });
  if (form === 'loose') {
    for (const [name, bytes] of mediaFixture) {
      await mkdir(path.dirname(path.join(root, name)), { recursive: true });
      await writeFile(path.join(root, name), bytes, { flag: 'wx' });
    }
  } else {
    await writeFile(path.join(root, 'scene.pkg'), mediaPackage, { flag: 'wx' });
    await writeFile(path.join(root, 'project.json'), JSON.stringify({ type: 'scene', file: 'scene.pkg', title: 'Owned media package' }), { flag: 'wx' });
  }
}
await writeFile(path.join(output, 'actual-media.json'), JSON.stringify(ownedMedia), { flag: 'wx' });
await writeFile(path.join(output, 'empty-media.json'), JSON.stringify(emptyMedia), { flag: 'wx' });
for (const mode of ['stale', 'frame']) {
  const root = path.join(output, `boundary-${mode}`);
  await mkdir(root, { recursive: true });
  const probe = mode === 'stale'
    ? `host.fetch('/__scene/config').then(r=>r.json()).then(config=>host.fetch('/__scene/event',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({type:'media-control',sceneID:config.sceneID+'-stale',generation:config.generation,command:'play',mediaRevision:1})}));`
    : `const frame=host.document.createElement('iframe');frame.src=host.location.origin+'/__runtime/index.html';host.document.body.append(frame);`;
  const script = `export function mediaPropertiesChanged(event){if(event.title!=='trigger-probe')return;const host=({}).constructor.constructor('return globalThis')();${probe}}`;
  await writeFile(path.join(root, 'project.json'), JSON.stringify({ type: 'scene', file: 'scene.json' }), { flag: 'wx' });
  await writeFile(path.join(root, 'scene.json'), JSON.stringify({
    general: { orthogonalprojection: { width: 640, height: 360 }, clearenabled: true, clearcolor: '0 0 0' },
    objects: [{ id: 1, name: `Owned ${mode} boundary probe`, solid: true, size: '160 80', origin: '320 180 0', color: { value: '1 1 1', script } }],
  }), { flag: 'wx' });
}
