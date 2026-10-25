import { SceneDocument, safePath } from './document.mjs';
import { createResourceClient, resourceReader, decodeResource } from './resources.mjs';
import { observeModelCapacity } from './model-capacity.mjs';
import { buildEditorPackage } from './package-archive.mjs';

// All renderers in the privileged authoring page share this execution policy.
// SceneScript playback belongs to the independent native scene page.
export function createWorkbenchScene(createScene, element, options) {
  return createScene(element,{...options,scripts:false});
}

export function createEditorSource(value, readOriginal, readVersion) {
  const document = structuredClone(value), read = resourceReader(document,readOriginal,readVersion);
  const encode = value => new TextEncoder().encode(JSON.stringify(value));
  return {
    async project() { return { ...document.project, type: 'scene', file: document.entry }; },
    async sceneDir() { return { entry: document.entry, async read(path) {
      safePath(path);
      if (path === document.entry) return encode(document.scene);
      if (path === 'project.json') return encode({ ...document.project, type: 'scene', file: document.entry });
      return read(path);
    } }; },
    async scenePkg() { throw new Error('Editor preview uses its owned loose scene'); },
  };
}
export function validateEditorCommand(command, config) {
  if (!command || command.session !== config.session || command.generation !== config.generation ||
      typeof command.id !== 'string' || !command.id) throw new Error('Stale Editor command');
  const fields = { snapshot: [], load: ['document'], 'mark-saved': ['document'], 'add-image': ['image'],
    'export-pkg': ['paths'], freeze: [], thaw: [], undo: [], redo: [],
    'replace-resource':['path','data'], 'import-model':['source'], 'resource-reply':['requestID','result'], seek:['time'] }[command.type];
  if (!fields || Object.keys(command).some(key => !['session', 'generation', 'id', 'type', ...fields].includes(key)) ||
      fields.some(key => command[key] === undefined)) throw new Error('Invalid Editor command');
}

export function startEditor(config, options) {
  if (config.version !== 1 || !config.session || !Number.isSafeInteger(config.generation) || config.generation < 1) throw new Error('Invalid Editor configuration');
  let document = new SceneDocument(config.document,config.sourcePackage), queue = Promise.resolve(), destroyed = false;
  let controls, instance, playing = true, frozen = true, modelCapacity;
  const report = payload => options.report({ ...payload, session: config.session, generation: config.generation });
  const resources = createResourceClient(report);
  const isDirty=()=>document.dirty||Boolean(options.draftDirty?.());
  const notifyDirty=()=>report({type:'dirty',dirty:isDirty()});
  const read = async path => {
    safePath(path);
    const response = await fetch(`/__project/${path.split('/').map(encodeURIComponent).join('/')}`, { redirect: 'error' });
    if (response.status === 404) return null;
    if (!response.ok) throw new Error(`Resource ${path}: HTTP ${response.status}`);
    return new Uint8Array(await response.arrayBuffer());
  };
  const zero = new Float32Array(64);
  const sceneOptions = { fps: 30, fit: 'contain', volume: 0,
    audio: { snapshot: () => ({ left: zero, right: zero }) }, media: null, autoQuality: false, debugHooks: false,
    onError: error => options.onError(error), onDiagnostic: (message, level) => {
      if (level === 'error') options.onError(new Error(message)); else if (level === 'warn') console.warn(message);
    } };
  async function render() {
    if (destroyed) throw new Error('Editor closed');
    const time = controls?.time ?? 0;
    // The pinned engine binds load() to its canvas after the first mount. A
    // structural edit needs a fresh instance/canvas after releasing the old GL context.
    modelCapacity?.dispose();instance?.destroy({ releasePkgCache: true }); controls = undefined;
    options.element.replaceChildren();
    const canvas=options.element.ownerDocument.createElement('canvas');
    canvas.style.cssText='position:absolute;inset:0;width:100%;height:100%;display:block';options.element.append(canvas);
    modelCapacity=observeModelCapacity(canvas);
    instance = createWorkbenchScene(options.createScene,canvas,sceneOptions);
    try {await instance.load(createEditorSource(document.snapshot(), read,resources.read));}
    finally {modelCapacity.dispose();}
    instance.setVolume(0); controls = options.editorOf(instance);
    if (!controls) throw new Error('The pinned engine did not expose Editor controls');
    controls.setTimeScale(playing ? 1 : 0); await controls.seek(time);
    options.onChange(document, controls);
  }
  function enqueue(operation) {
    const result = queue.then(operation);
    // Keep the serial queue usable after a visible, recoverable edit failure.
    queue = result.catch(error => { options.onError(error); });
    return result;
  }
  async function changed(operation) {
    if (frozen) throw new Error('Editor is frozen for a native operation');
    operation(document);
    await notifyDirty();
    return enqueue(render);
  }
  function setPlaying(value) {
    playing=value; controls?.setTimeScale(value ? 1 : 0); options.onPlaybackChange?.(playing);
  }
  async function requestPreview() {
    if (destroyed || frozen) throw new Error('Editor is closed or frozen');
    // Wait only for transport: native capture must be able to freeze this page.
    await report({type:'preview'});
  }
  function seek(time) {
    if (destroyed || frozen) return Promise.reject(new Error('Editor is closed or frozen'));
    if (!Number.isFinite(time) || time < 0) return Promise.reject(new Error('Invalid timeline time'));
    return enqueue(()=>controls.seek(time));
  }
  function previewModel(id,animation,time,poses=[]) {
    if(destroyed||frozen)return Promise.reject(new Error('Editor is closed or frozen'));
    if(!Number.isFinite(time)||time<0)return Promise.reject(new Error('Invalid model preview time'));
    const source=document;
    return enqueue(async()=>{
      const info=controls?.getModelInfo(id);
      if(document!==source||!info?.animations.some(clip=>clip.id===animation))throw new Error('Model document changed or animation clip is unavailable');
      if(poses.some(pose=>!Number.isInteger(pose.bone)||pose.bone<0||pose.bone>=info.bones.length))throw new Error('Invalid preview bone');
      setPlaying(false);await controls.setAnimationLayers(id,[{animation,blend:1,rate:1,visible:true}]);await controls.seek(time);
      for(const pose of poses)await controls.setBonePose(id,pose.bone,pose.value);
    });
  }
  function previewModelClip(id,animation,time=0){return previewModel(id,animation,time);}
  function previewModelBonePoses(id,{animation,time,poses}) {
    if(!Array.isArray(poses)||!poses.length||new Set(poses.map(pose=>pose?.bone)).size!==poses.length)return Promise.reject(new Error('Expected distinct preview bones'));
    const values=[];
    for(const pose of poses){
      const delta=pose?.delta;
      if(!Array.isArray(delta)||delta.length!==9||!delta.every(Number.isFinite))return Promise.reject(new Error('Invalid bone delta'));
      const encoded=Array.from(Float32Array.from(delta));
      if(encoded.some((v,i)=>!Number.isFinite(v)||v===0&&(delta[i]!==0||i>=6)))return Promise.reject(new Error('Bone delta is singular or cannot be represented in Float32'));
      values.push({bone:pose.bone,value:{t:encoded.slice(0,3),r:encoded.slice(3,6),s:encoded.slice(6)}});
    }
    return previewModel(id,animation,time,values);
  }
  function previewModelBonePose(id,{animation,bone,time,delta}){return previewModelBonePoses(id,{animation,time,poses:[{bone,delta}]});}
  function restoreModelPreview({time,playing:resume}) {
    if(destroyed||frozen)return Promise.reject(new Error('Editor is closed or frozen'));
    if(!Number.isFinite(time)||time<0||typeof resume!=='boolean')return Promise.reject(new Error('Invalid model playback state'));
    return enqueue(async()=>{setPlaying(false);await render();await controls.seek(time);setPlaying(resume);});
  }
  const ready = enqueue(async () => { await render(); await report({ type: 'ready', frame: 1 }); });
  async function applyCommand(value) {
    try {
      validateEditorCommand(value, config);
      // Initial rendering and an in-progress native command can both need a blob.
      // Resolving a resource must never wait for that same render/command queue.
      if (value.type === 'resource-reply') {
        resources.reply(value);
        await report({type:'reply',id:value.id,payload:{}}); return;
      }
      await queue;
      if(['load','add-image','replace-resource','import-model','export-pkg'].includes(value.type)&&options.snapshotError?.())throw options.snapshotError();
      let payload = {};
      switch (value.type) {
        case 'snapshot': if (options.snapshotError?.()) throw options.snapshotError(); payload = { document: document.snapshot() }; break;
        case 'freeze': frozen = true; options.setEditingEnabled(false); payload = { document:document.snapshot(), dirty:isDirty() || Boolean(options.snapshotError?.()) }; break;
        case 'thaw': frozen = false; options.setEditingEnabled(true); break;
        case 'load': document = new SceneDocument(value.document,config.sourcePackage); await render(); break;
        case 'mark-saved': document.markSaved(value.document); options.onChange(document, controls); break;
        case 'add-image': await changed(doc => doc.addImage(value.image)); break;
        case 'import-model': if(frozen)throw new Error('Editor is frozen for a native operation');await options.importModel(value.source);break;
        case 'undo': if(options.snapshotError?.())throw options.snapshotError();await changed(doc => doc.undo()); break;
        case 'redo': if(options.snapshotError?.())throw options.snapshotError();await changed(doc => doc.redo()); break;
        case 'seek': setPlaying(false); await seek(value.time); payload={time:controls.time}; break;
        case 'replace-resource': {
          if (frozen) throw new Error('Editor is frozen for a native operation');
          // Validate the target before staging any bytes on disk.
          const draft = new SceneDocument(document.snapshot(),config.sourcePackage);
          draft.resource(value.path,'0'.repeat(64));
          const version = await resources.stage(decodeResource(value.data));
          await changed(doc => doc.transaction(draft => draft.resource(value.path,version))); break;
        }
        case 'export-pkg': {
          if (!Array.isArray(value.paths) || !value.paths.every(path => typeof path === 'string')) throw new Error('Invalid resource list');
          const snapshot = document.snapshot(), encode = object => new TextEncoder().encode(JSON.stringify(object));
          const resolve = resourceReader(snapshot,read,resources.read);
          const files = [];
          for (const path of new Set([...value.paths,...Object.keys(snapshot.resourceOverrides ?? {})])) {
            safePath(path);
            if (path === 'project.json' || path === snapshot.entry || path === config.sourcePackage) continue;
            const bytes = await resolve(path); if (bytes === null) throw new Error(`Export resource disappeared: ${path}`);
            files.push({ path, data: bytes });
          }
          files.push({ path: 'scene.json', data: encode(snapshot.scene) });
          const result = buildEditorPackage(files,options.buildScenePkg);
          // Upstream checkWeCompat resolves project.file as the entry *inside*
          // the container; exported Main metadata still declares scene.pkg.
          const report = await options.checkWeCompat([{ path: 'project.json', data: encode({ ...snapshot.project, file: 'scene.json' }) },
            { path: 'scene.pkg', data: result.pkg }]);
          if (!report.ok) throw new Error(`PKG compatibility: ${JSON.stringify(report.issues)}`);
          let base64 = ''; for (let offset = 0; offset < result.pkg.length; offset += 32768) base64 += String.fromCharCode(...result.pkg.subarray(offset, offset + 32768));
          payload = { pkg: btoa(base64), converted: result.converted, dropped: result.dropped }; break;
        }
      }
      await notifyDirty();
      await report({ type: 'reply', id: value.id, payload });
    } catch (error) {
      options.onError(error);
      await report({ type: 'reply', id: value.id, payload: { error: String(error?.message ?? error) } });
    }
  }
  let commandQueue = Promise.resolve();
  function command(value) {
    if (value?.type === 'resource-reply') return applyCommand(value);
    const result = commandQueue.then(() => applyCommand(value)); commandQueue = result.catch(options.onError); return result;
  }
  return { ready, command, change: changed, get controls() { return controls; }, get document() { return document; },
    get playing() { return playing; }, get frozen() { return frozen; }, setPlaying,requestPreview,notifyDirty,seek,previewModelClip,previewModelBonePose,previewModelBonePoses,restoreModelPreview,
    stageResource:resources.stage,resourcePaths:resources.paths,
    readResource(path) {if(destroyed)return Promise.reject(new Error('Editor closed'));return resourceReader(document.snapshot(),read,resources.read)(path);},
    get modelBoneCapacity(){if(modelCapacity?.error)throw modelCapacity.error;return modelCapacity?.capacity;},
    destroy() { destroyed = true; modelCapacity?.dispose();resources.dispose(); instance?.destroy({ releasePkgCache: true }); } };
}
