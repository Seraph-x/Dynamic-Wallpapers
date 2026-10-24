#!/usr/bin/env node
// Self-authored single-entry PKGV0012 fixture; offsets are relative to payload.
import { readFile, writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const uint32 = value => { const bytes = Buffer.alloc(4); bytes.writeUInt32LE(value); return bytes; };
const text = value => { const bytes = Buffer.from(value); return Buffer.concat([uint32(bytes.length), bytes]); };
const scene = await readFile(new URL('../Tests/Fixtures/SceneAnimatedLoose/scene.json', import.meta.url));
const bytes = Buffer.concat([text('PKGV0012'), uint32(1), text('scene.json'), uint32(0), uint32(scene.length), scene]);
const output = new URL('../Tests/Fixtures/SceneAnimatedPackage/scene.pkg', import.meta.url);
if (process.argv.includes('--check')) assert.deepEqual(await readFile(output), bytes);
else await writeFile(output, bytes);
