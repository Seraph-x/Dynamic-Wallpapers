import { projectPath } from './scene-protocol.mjs';

// A single source owns all requests and cached bytes until engine destruction.
// Optional missing resources return null; denied or failed reads are fatal.
export function createProjectSource(project, options = {}) {
  const request = options.fetch ?? globalThis.fetch.bind(globalThis);
  const origin = options.origin ?? globalThis.location.origin;
  const entry = projectPath(project.entryPath);
  const controller = new AbortController();
  const cache = new Map();
  let metadata;
  function signalFor(signal) {
    const combined = signal ? AbortSignal.any([controller.signal, signal]) : controller.signal;
    combined.throwIfAborted();
    return combined;
  }
  async function read(name, signal, optional = true) {
    const requestSignal = signalFor(signal);
    try {
      const path = projectPath(name);
      if (cache.has(path)) return cache.get(path);
      const response = await request(`${origin}/__project/${path}`, { signal: requestSignal, credentials: 'same-origin', redirect: 'error' });
      if (response.status === 404 && optional) return null;
      if (!response.ok) throw new Error(`Scene resource ${name}: HTTP ${response.status}`);
      const bytes = new Uint8Array(await response.arrayBuffer());
      requestSignal.throwIfAborted();
      cache.set(path, bytes);
      return bytes;
    } catch (error) {
      if (!requestSignal.aborted) options.onError?.(error);
      throw error;
    }
  }
  const directory = Object.freeze({ entry: project.entryPath, read, bytes: () => [...cache.values()].reduce((total, value) => total + value.byteLength, 0) });
  return Object.freeze({
    key: `${origin}/__project`,
    async project(signal) {
      signalFor(signal);
      if (metadata) return metadata;
      const bytes = await read('project.json', signal, false);
      const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
      if (!value || typeof value !== 'object' || Array.isArray(value) || value.type?.toLowerCase() !== 'scene') throw new Error('Project metadata must describe a scene');
      // Imported representation is authoritative, even when upstream metadata
      // declares scene.json but the actual imported representation is scene.pkg.
      metadata = { ...value, type: 'scene', file: project.entryPath };
      return metadata;
    },
    async sceneDir(signal) { signalFor(signal); return project.representation === 'loose' ? directory : null; },
    async scenePkg(signal) {
      if (project.representation !== 'package') throw new Error('Cannot read scene.pkg for a loose scene');
      return read(project.entryPath, signal, false);
    },
    dispose() { controller.abort(); cache.clear(); metadata = undefined; },
  });
}
