import { createRequire } from 'node:module';
import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const web = path.dirname(fileURLToPath(import.meta.url)), repo = path.resolve(web,'../..');
const require = createRequire(path.join(web,'.build/package.json'));
const { build } = require('esbuild');
const output = path.join(repo,'Editor/Sources/EditorApp/Resources/EditorWeb');
const previewOutput = path.join(repo,'Editor/Sources/EditorApp/Resources/ScenePreviewWeb');
const check = process.argv.includes('--check');
const provenancePath = path.join(repo,'Editor/ThirdParty/provenance.json');
const expected = JSON.parse(await readFile(provenancePath));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
await mkdir(output,{recursive:true});
const pins = {'@webwallgl/editor':'3.0.0',webwallgl:'3.0.0',mediabunny:'1.56.0',esbuild:'0.28.2',codemirror:'6.0.2','@codemirror/lang-javascript':'6.2.5','@codemirror/autocomplete':'6.20.4','@codemirror/commands':'6.11.1','@codemirror/search':'6.7.2','@codemirror/view':'6.43.15','@codemirror/state':'6.7.6','@codemirror/language':'6.13.1','@lezer/highlight':'1.2.5'};
for (const [name,version] of Object.entries(pins)) {
  const metadata = JSON.parse(await readFile(path.join(web,'.build/node_modules',name,'package.json')));
  if (metadata.version !== version) throw new Error(`Unpinned ${name}`);
}
const mainProvenance = JSON.parse(await readFile(path.join(repo,'Resources/ThirdParty/WebWallGL/provenance.json')));
const modelProvenance = JSON.parse(await readFile(path.join(repo,'Editor/ThirdParty/mdl-codec-provenance.json')));
for(const [name,digest] of Object.entries(modelProvenance.files)) {
  if(hash(await readFile(path.join(repo,name)))!==digest)throw new Error(`Pinned model codec differs: ${name}`);
}
const gltfProvenance=JSON.parse(await readFile(path.join(repo,'Editor/ThirdParty/gltf-provenance.json')));
for(const [name,digest] of Object.entries(gltfProvenance.files))if(hash(await readFile(path.join(repo,name)))!==digest)throw new Error(`Pinned glTF helper differs: ${name}`);
const enginePath = 'Sources/WallpaperApp/Resources/SceneRuntime/webwallgl.bundle.mjs';
const engine = await readFile(path.join(repo,enginePath));
if (hash(engine) !== mainProvenance.files[enginePath]) throw new Error('Shared engine hash mismatch');
const entry = require.resolve('@webwallgl/editor');
if (hash(await readFile(entry)) !== expected.editorEntrySHA256) throw new Error('Pinned editor API source hash mismatch');
const bundled = await build({entryPoints:[entry],outfile:'editor-api.mjs',bundle:true,platform:'browser',format:'esm',target:'chrome120',minify:true,
  legalComments:'eof',write:false,plugins:[{name:'shared-engine',setup(builder){builder.onResolve({filter:/^webwallgl$/},()=>({path:'./webwallgl.bundle.mjs',external:true}));}}]});
const files = {};
async function put(name,bytes) {
  files[name]=hash(bytes);
  if (check) { if (hash(await readFile(path.join(output,name))) !== files[name]) throw new Error(`Editor resource differs from reproducible build: ${name}`); }
  else await writeFile(path.join(output,name),bytes);
}
await put('editor-api.mjs',bundled.outputFiles[0].contents);
const model = await build({entryPoints:[path.join(web,'model-api-entry.mjs')],outfile:'model-api.mjs',bundle:true,platform:'browser',format:'esm',target:'chrome120',minify:true,legalComments:'eof',write:false});
await put('model-api.mjs',model.outputFiles[0].contents);
const scripts=await build({entryPoints:[path.join(web,'script-api-entry.mjs')],nodePaths:[path.join(web,'.build/node_modules')],outfile:'script-api.mjs',bundle:true,platform:'browser',format:'esm',target:'chrome120',minify:true,legalComments:'eof',write:false,metafile:true});
if(Object.values(scripts.metafile.outputs).some(file=>file.imports.length))throw new Error('Compile-only Script API must not load renderer or other modules');
await put('script-api.mjs',scripts.outputFiles[0].contents);
const codeEditor=await build({entryPoints:[path.join(web,'code-editor-entry.mjs')],nodePaths:[path.join(web,'.build/node_modules')],outfile:'code-editor-api.mjs',bundle:true,platform:'browser',format:'esm',target:'chrome120',minify:true,legalComments:'eof',write:false,metafile:true});
if(Object.values(codeEditor.metafile.outputs).some(file=>file.imports.length))throw new Error('Code editor bundle must remain offline');
await put('code-editor-api.mjs',codeEditor.outputFiles[0].contents);

await put('webwallgl.bundle.mjs',engine);
for (const name of ['index.html','editor.css','app.mjs','document.mjs','runtime.mjs','script-source.mjs','script-draft.mjs','script-workspace.mjs','script-workspace-view.mjs','script-workspace-targets.mjs','script-navigation.mjs','script-navigation-messages.mjs','captured-script-view.mjs','code-editor.mjs','code-editor-messages.mjs','script-language.mjs','script-workspace-messages.mjs','script-workspace.css','script-mode-messages.mjs','localization.mjs','interface.mjs','resources.mjs','animation.mjs','timeline-clock.mjs','timeline-view.mjs','timeline.mjs','timeline-messages.mjs','timeline.css','model-capacity.mjs','model-resource-edit.mjs','model-workspace.mjs','model-view.mjs','model-overlay.mjs','model-messages.mjs','model.css','image-puppet-view.mjs','model-brush-view.mjs','model-brush-controller.mjs','model-projection.mjs','model-rest-view.mjs','gltf.css','gltf-messages.mjs','gltf-import.mjs','gltf-import-view.mjs','gltf-import-edit.mjs','gltf-preview.mjs','package-archive.mjs','model-clip-tools.mjs','model-clips-view.mjs','model-clips-messages.mjs','model-clip-edit.mjs','model-pose-tools.mjs','model-pose-view.mjs','model-pose-messages.mjs','model-mixing.mjs','model-mixing-tools.mjs','model-mixing-view.mjs','model-mixing-messages.mjs','model-events-tools.mjs','model-events-view.mjs','model-events-messages.mjs','model-fk-tools.mjs','model-fk-view.mjs','model-fk-messages.mjs','model-ik-tools.mjs','model-ik-view.mjs','model-ik-messages.mjs','model-keys-tools.mjs','model-keys-view.mjs','model-keys-messages.mjs']) await put(name,await readFile(path.join(web,name)));
await mkdir(path.join(repo,'Editor/ThirdParty'),{recursive:true});
if (!check) await copyFile(path.join(web,'.build/node_modules/@webwallgl/editor/LICENSE'),path.join(repo,'Editor/ThirdParty/WebWallGL-Editor-LICENSE'));
const codePackages={};
for(const input of Object.keys(codeEditor.metafile.inputs)) {
  const marker='node_modules/',offset=input.lastIndexOf(marker);if(offset<0)continue;
  const parts=input.slice(offset+marker.length).split('/'),name=parts[0].startsWith('@')?parts.slice(0,2).join('/'):parts[0];
  const metadata=JSON.parse(await readFile(path.join(web,'.build/node_modules',name,'package.json')));
  codePackages[name]=metadata.version;
}
const codeLicenses=[];
for(const name of Object.keys(codePackages).sort())codeLicenses.push(name+' '+codePackages[name]+'\n'+await readFile(path.join(web,'.build/node_modules',name,'LICENSE'),'utf8'));
const licenseBytes=Buffer.from(codeLicenses.join('\n\n'));const codeLicensePath=path.join(repo,'Editor/ThirdParty/CodeMirror-LICENSES.txt');
if(check){if(hash(await readFile(codeLicensePath))!==hash(licenseBytes))throw new Error('CodeMirror licenses differ');}else await writeFile(codeLicensePath,licenseBytes);
const provenance={schema:1,packages:pins,codeEditorPackages:Object.fromEntries(Object.entries(codePackages).sort(([a],[b])=>a.localeCompare(b))),editorEntrySHA256:hash(await readFile(entry)),engineSHA256:hash(engine),files};
const previewFiles={};
await mkdir(previewOutput,{recursive:true});
async function putPreview(name,bytes) {
  previewFiles[name]=hash(bytes);
  if(check){if(hash(await readFile(path.join(previewOutput,name)))!==previewFiles[name])throw new Error(`Editor preview resource differs from reproducible build: ${name}`);}
  else await writeFile(path.join(previewOutput,name),bytes);
}
// Preserve Main's trusted entry and playback modules byte-for-byte. Only the
// Editor shell selects the closure-scoped, read-only issue observer wrapper.
for(const name of ['index.html','scene.css','scene-runtime.mjs','scene-spectrum.mjs','scene-source.mjs','scene-protocol.mjs','scene-properties.mjs','webwallgl.bundle.mjs']) {
  await putPreview(name,await readFile(path.join(repo,'Sources/WallpaperApp/Resources/SceneRuntime',name)));
}
await putPreview('scene-shell.mjs',await readFile(path.join(web,'scene-preview-shell.mjs')));
const previewObserver=await build({entryPoints:[path.join(web,'scene-preview-script.mjs')],nodePaths:[path.join(web,'.build/node_modules')],outfile:'scene-preview-api.mjs',bundle:true,platform:'browser',format:'esm',target:'chrome120',minify:true,legalComments:'eof',write:false,metafile:true,
  plugins:[{name:'shared-preview-engine',setup(builder){builder.onResolve({filter:/^webwallgl$/},()=>({path:'./webwallgl.bundle.mjs',external:true}));}}]});
for(const file of Object.values(previewObserver.metafile.outputs)) {
  if(file.imports.some(item=>item.path!=='./webwallgl.bundle.mjs'||item.kind!=='import-statement')||file.exports.some(name=>name!=='createPreviewSceneFactory'))throw new Error('Preview observer must expose only its playback factory and share the pinned offline engine');
}
await putPreview('scene-preview-api.mjs',previewObserver.outputFiles[0].contents);
provenance.previewFiles=previewFiles;
if (check) { if (JSON.stringify(expected) !== JSON.stringify(provenance)) throw new Error('Editor provenance differs from reproducible build'); }
else await writeFile(provenancePath,JSON.stringify(provenance,null,2)+'\n');
console.log(`${check?'Verified':'Bundled'} Editor offline resources: ${Object.keys(files).length} workbench + ${Object.keys(previewFiles).length} preview`);
