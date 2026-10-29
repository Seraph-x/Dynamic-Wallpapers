import { createPreviewSceneFactory } from './scene-preview-api.mjs';
import { createMediaSource } from './webwallgl.bundle.mjs';
import { startSceneRuntime } from './scene-runtime.mjs';
import { pollSpectrum } from './scene-spectrum.mjs';

const response = await fetch('/__scene/config', { credentials: 'same-origin', redirect: 'error' });
if (!response.ok) throw new Error(`Scene configuration: HTTP ${response.status}`);
const config = await response.json();
const report = async (event, {signal} = {}) => {
    const result = await fetch('/__scene/event', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin', redirect: 'error', body: JSON.stringify(event), signal,
    });
    if (!result.ok) throw new Error(`Scene event ${event.type}: HTTP ${result.status}`);
};
const runtime = startSceneRuntime(config, {
  createMediaSource,
  createScene: createPreviewSceneFactory({...config,report}),
  element: document.getElementById('scene'),
  startSpectrum: (source, onError) => pollSpectrum(source, { onError }),
  report,
});
Object.defineProperty(window, '__dynamicWallpaperScene', { value: Object.freeze({ command: runtime.command }), configurable: false, writable: false });
window.addEventListener('pagehide', runtime.destroy, { once: true });
window.addEventListener('error', event => runtime.fail(event.error ?? new Error(event.message)));
window.addEventListener('unhandledrejection', event => runtime.fail(event.reason));
await runtime.ready;

const canvas = document.querySelector('#scene canvas');
const gl = canvas?.getContext('webgl2');
if (!gl) throw new Error('Scene did not create a WebGL2 canvas');
const debug = gl.getExtension('WEBGL_debug_renderer_info');
console.info('Scene WebGL', JSON.stringify({
  width: canvas.width, height: canvas.height, devicePixelRatio,
  vendor: gl.getParameter(debug ? debug.UNMASKED_VENDOR_WEBGL : gl.VENDOR),
  renderer: gl.getParameter(debug ? debug.UNMASKED_RENDERER_WEBGL : gl.RENDERER),
}));
