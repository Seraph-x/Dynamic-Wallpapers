// The host supplies real audio or explicit silence; never use simulated input.
export function createSpectrumSource(config) {
  const zero = () => ({ left: new Float32Array(64), right: new Float32Array(64) });
  let latest = zero();
  const channel = values => {
    if (!Array.isArray(values) || values.length !== 64 || !values.every(value =>
      typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1)) {
      throw new Error('Invalid scene spectrum channel');
    }
    return Float32Array.from(values);
  };
  return Object.freeze({
    snapshot: () => latest,
    clear: () => { latest = zero(); },
    update: value => {
      if (!value || value.sceneID !== config.sceneID || value.generation !== config.generation) {
        throw new Error('Stale scene spectrum identity');
      }
      latest = { left: channel(value.left), right: channel(value.right) };
    },
  });
}

export function pollSpectrum(source, options) {
  const controller = new AbortController();
  let timer;
  const stop = () => { controller.abort(); clearTimeout(timer); };
  const request = options.fetch ?? globalThis.fetch;
  const poll = async () => {
    try {
      const response = await request('/__scene/spectrum', {
        credentials: 'same-origin', redirect: 'error', cache: 'no-store', signal: controller.signal,
      });
      if (!response.ok) throw new Error(`Scene spectrum: HTTP ${response.status}`);
      const value = await response.json();
      if (controller.signal.aborted) return;
      source.update(value);
      // Schedule only after completion: slow requests cannot build up a queue.
      timer = setTimeout(poll, 1000 / 30);
    } catch (error) {
      if (controller.signal.aborted) return;
      stop(); source.clear?.(); options.onError(error);
    }
  };
  void poll();
  return stop;
}
