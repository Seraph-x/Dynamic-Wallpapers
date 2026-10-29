import { validateConfig, validateCommand } from './scene-protocol.mjs';
import { createProjectSource } from './scene-source.mjs';
import { createSpectrumSource } from './scene-spectrum.mjs';
import { createPropertyCatalog, validatePropertyPatch } from './scene-properties.mjs';
import { createSceneMediaSource } from './scene-media.mjs';

function errorMessage(error) {
  const text = String(error?.message ?? error);
  const bytes = new TextEncoder().encode(text || 'Unknown scene failure');
  return new TextDecoder().decode(bytes.slice(0, 2045));
}

export function startSceneRuntime(value, options) {
  const config = validateConfig(value);
  let destroyed = false, failed = false, loaded = false;
  let instance;
  let commands = Promise.resolve();
  let fps = config.fps;
  const spectrum = createSpectrumSource(config);
  let stopSpectrum;
  let propertyCatalog;
  const event = payload => options.report({ ...payload, sceneID: config.sceneID, generation: config.generation });
  const media = createSceneMediaSource({ createMediaSource: options.createMediaSource, report: event,
    onError: error => console.error('System media control reporting failed', error) });
  const destroy = () => {
    if (destroyed) return;
    destroyed = true;
    stopSpectrum?.(); spectrum.clear();
    media.dispose();
    source.dispose();
    instance?.destroy({ releasePkgCache: true });
  };
  const fail = error => {
    if (destroyed || failed) return;
    failed = true;
    console.error('Scene wallpaper failed', error);
    destroy();
    void event({ type: 'error', message: errorMessage(error) }).catch(reportError => console.error('Scene failure reporting failed', reportError));
  };
  const source = createProjectSource(config.project, { ...options.sourceOptions, onError: fail });
  instance = options.createScene(options.element, {
    fps: config.fps, fit: config.fit, volume: config.muted ? 0 : config.volume,
    audio: spectrum, media: media.source, autoQuality: false, debugHooks: false,
    onError: fail,
    onDiagnostic: (message, level) => {
      if (level === 'error') fail(new Error(message));
      else if (level === 'warn') console.warn('Scene engine', message);
    },
  });
  stopSpectrum = options.startSpectrum?.(spectrum, fail);
  // load resolves only after WebWallGL's real first frame. HTML/RAF callbacks do
  // not prove readiness. Native also waits for a later committed CEF pixel frame.
  const ready = instance.load(source).then(async () => {
    if (destroyed) throw new Error('Scene was destroyed during preparation');
    loaded = true;
    await event({ type: 'ready', frame: 1 });
  }).catch(error => { fail(error); throw error; });

  // Engine cursor hooks consume button edges during render frames. Keep each
  // edge through two frame periods; an immediate down/up pair is never seen.
  const pointerFrame = () => new Promise(resolve => {
    const start = performance.now();
    const tick = now => now - start >= 2000 / fps ? resolve() : requestAnimationFrame(tick);
    requestAnimationFrame(tick);
  });
  async function apply(command) {
    validateCommand(command, config);
    if (!loaded || destroyed || failed) throw new Error('Scene is not ready for commands');
    switch (command.type) {
      case 'play': instance.resume(); break;
      case 'pause': instance.pause(); break;
      case 'volume': instance.setVolume(command.muted ? 0 : command.volume); break;
      case 'fit': instance.setFit(command.fit); break;
      case 'fps': fps = command.fps; instance.setFps(fps); break;
      case 'media': {
        media.replace(command.media, command.mediaRevision);
        await instance.setMedia(media.source);
        if (destroyed || failed) throw new Error('Scene destroyed during media update');
        break;
      }
      case 'properties': {
        propertyCatalog ??= createPropertyCatalog(await source.project());
        if (destroyed || failed) throw new Error('Scene destroyed during property preparation');
        const patch = validatePropertyPatch(command.properties, propertyCatalog);
        await instance.setProperties(patch);
        if (destroyed || failed) throw new Error('Scene destroyed during property update');
        break;
      }
      case 'pointer':
        if (command.kind === 'click' && instance.paused) throw new Error('Cannot dispatch a scene click while playback is paused');
        if (command.kind === 'leave') instance.pointerLeave();
        else {
          instance.pushPointer(command.x, command.y, command.kind === 'click' ? 1 : 0);
          if (command.kind === 'click') {
            await pointerFrame();
            if (destroyed) throw new Error('Scene destroyed during pointer press');
            instance.pushPointer(command.x, command.y, 0);
            await pointerFrame();
          }
        }
        break;
      case 'destroy': destroy(); break;
    }
    return event({ type: 'command-ack', commandID: command.id });
  }
  function command(payload) {
    commands = commands.then(() => apply(payload)).catch(fail);
    return commands;
  }
  return Object.freeze({ ready, command, destroy, fail });
}
