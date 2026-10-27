#!/usr/bin/env node
// Authored properties and independent GPU oracles shared with browser acceptance.
import {mkdir, writeFile} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {propertiesDocument} from '../Editor/Web/preview-properties-fixture.mjs';

const output = resolve(process.argv[2]);
await mkdir(output);
const uint32 = value => {const bytes = Buffer.alloc(4); bytes.writeUInt32LE(value); return bytes;};
const text = value => {const bytes = Buffer.from(value); return Buffer.concat([uint32(bytes.length), bytes]);};
const scene = Buffer.from(JSON.stringify(propertiesDocument.scene));
for (const representation of ['loose', 'package']) {
  const directory = join(output, representation);
  await mkdir(directory);
  const project = structuredClone(propertiesDocument.project);
  project.file = representation === 'loose' ? 'scene.json' : 'scene.pkg';
  await writeFile(join(directory, 'project.json'), JSON.stringify(project));
  const bytes = representation === 'loose' ? scene : Buffer.concat([
    text('PKGV0012'), uint32(1), text('scene.json'), uint32(0), uint32(scene.length), scene,
  ]);
  await writeFile(join(directory, project.file), bytes);
}
