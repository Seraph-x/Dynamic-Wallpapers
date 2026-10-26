import { createScene, editorOf } from '@webwallgl/editor';
import { observeScriptIssues } from './script-diagnostics.mjs';

// Keep the renderer and its editor controls inside this closure. Scene runtime
// receives only the playback facade it already uses in Main.
export function createPreviewSceneFactory({sceneID,generation,report}) {
  return (element,options) => {
    const instance = createScene(element,options);
    let destroyed = false, stopObserver, controls;
    return Object.freeze({
      async load(source) {
        const result = await instance.load(source);
        if (destroyed) return result;
        controls = editorOf(instance);
        if (!controls || typeof controls.getScriptIssues !== 'function') throw new Error('Pinned scene script issue read API unavailable');
        stopObserver = observeScriptIssues({
          sceneID,generation,report,
          read: () => controls.getScriptIssues(),
          onError: options.onError,
        });
        return result;
      },
      resume: () => instance.resume(),
      pause: () => instance.pause(),
      get paused() { return instance.paused; },
      setVolume: value => instance.setVolume(value),
      setFit: value => instance.setFit(value),
      setFps: value => instance.setFps(value),
      async setProperties(properties) {
        if (destroyed) throw new Error('Scene is destroyed');
        if (!controls || typeof controls.declareUserProperties !== 'function') throw new Error('Pinned scene user-property API unavailable');
        const declarations = Object.create(null);
        for (const [name, value] of Object.entries(properties)) declarations[name] = { value };
        // Existing names receive values only: no authoring metadata is sent.
        // The pin's promise resolves after its actual next/paused render frame.
        await controls.declareUserProperties(declarations);
        if (destroyed) throw new Error('Scene destroyed during property update');
      },
      pushPointer: (x,y,buttons) => instance.pushPointer(x,y,buttons),
      pointerLeave: () => instance.pointerLeave(),
      destroy(destroyOptions) {
        if (destroyed) return;
        destroyed = true;
        stopObserver?.();
        instance.destroy(destroyOptions);
      },
    });
  };
}
