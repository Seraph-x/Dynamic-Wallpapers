#!/usr/bin/env node
// npm ci --prefix scripts/scene-runtime-build && node scripts/scene-bundle.mjs
// No npm dependency or network connection is needed by the shipped app.
import { createRequire } from 'node:module';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const buildRoot = path.join(root, 'scripts/scene-runtime-build');
const require = createRequire(path.join(buildRoot, 'package.json'));
const { build } = require('esbuild');
const provenancePath = path.join(root, 'Resources/ThirdParty/WebWallGL/provenance.json');
const provenance = JSON.parse(await readFile(provenancePath));
const engine = path.dirname(require.resolve('webwallgl/package.json'));
const engineBytes = await readFile(path.join(engine, 'webwallgl.mjs'));
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
if (digest(engineBytes) !== provenance.engine.entrySHA256) throw new Error('Pinned WebWallGL entry hash mismatch');
for (const [name, expected] of [['webwallgl', '3.0.0'], ['mediabunny', '1.56.0'], ['esbuild', '0.28.2']]) {
  const installed = JSON.parse(await readFile(path.join(buildRoot, 'node_modules', name, 'package.json')));
  if (installed.version !== expected) throw new Error(`Wrong ${name} version: ${installed.version}`);
}
const output = 'Sources/WallpaperApp/Resources/SceneRuntime/webwallgl.bundle.mjs';
const result = await build({
  absWorkingDir: buildRoot, entryPoints: [path.join(engine, 'webwallgl.mjs')], outfile: path.join(root, output),
  bundle: true, format: 'esm', platform: 'browser', target: 'chrome120', minify: true,
  legalComments: 'eof', treeShaking: true, sourcemap: false, write: false,
});
const bytes = result.outputFiles[0].contents;
if (process.argv.includes('--check')) {
  if (digest(bytes) !== digest(await readFile(path.join(root, output))) || digest(bytes) !== provenance.files[output]) throw new Error('Checked-in scene bundle differs from reproducible build');
} else {
  await writeFile(path.join(root, output), bytes);
  provenance.files[output] = digest(bytes);
  await writeFile(provenancePath, JSON.stringify(provenance, null, 2) + '\n');
}
console.log(`${output}: ${provenance.files[output]}`);
