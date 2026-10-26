import { createScene, editorOf } from '@webwallgl/editor';
import { observeScriptIssues } from './script-diagnostics.mjs';

// Keep the renderer and its editor controls inside this closure. Scene runtime
// receives only the playback facade it already uses in Main.
export function createPreviewSceneFactory({sceneID,generation,report}) {
  return (element,options) => {
    const instance = createScene(element,options);
    let destroyed = false, stopObserver;
    return Object.freeze({
      async load(source) {
        const result = await instance.load(source);
        if (destroyed) return result;
        const controls = editorOf(instance);
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
