#!/usr/bin/env node
// npm ci --prefix scripts/scene-runtime-build && node scripts/scene-bundle.mjs
// No npm dependency or network connection is needed by the shipped app.
import { createRequire } from 'node:module';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { patchSceneEngine } from './scene-engine-patches.mjs';

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
const patched=patchSceneEngine(engineBytes.toString('utf8'));
const localPatches={source:'scripts/scene-engine-patches.mjs',sha256:digest(await readFile(new URL('./scene-engine-patches.mjs',import.meta.url))),patchedEntrySHA256:digest(patched.source),items:patched.patches};
const result = await build({
  absWorkingDir: buildRoot, entryPoints: [path.join(engine, 'webwallgl.mjs')], outfile: path.join(root, output),
  bundle: true, format: 'esm', platform: 'browser', target: 'chrome120', minify: true,
  legalComments: 'eof', treeShaking: true, sourcemap: false, write: false,
  plugins:[{name:'recorded-scene-patches',setup(builder){builder.onLoad({filter:/webwallgl\.mjs$/},args=>args.path===path.join(engine,'webwallgl.mjs')?{contents:patched.source,loader:'js',resolveDir:engine}:undefined);}}],
});
const bytes = result.outputFiles[0].contents;
if (process.argv.includes('--check')) {
  if(JSON.stringify(provenance.localPatches)!==JSON.stringify(localPatches))throw new Error('Recorded scene engine patches differ from reproducible build');
  if (digest(bytes) !== digest(await readFile(path.join(root, output))) || digest(bytes) !== provenance.files[output]) throw new Error('Checked-in scene bundle differs from reproducible build');
} else {
  await writeFile(path.join(root, output), bytes);
  provenance.files[output] = digest(bytes);
  provenance.localPatches=localPatches;
  await writeFile(provenancePath, JSON.stringify(provenance, null, 2) + '\n');
}
console.log(`${output}: ${provenance.files[output]}`);
