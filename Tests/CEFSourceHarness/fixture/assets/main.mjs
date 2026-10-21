import { value } from './value.mjs';

function resultFrom(worker, port = worker) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Worker response timed out')), 4000);
    port.onmessage = event => { clearTimeout(timer); resolve(event.data); };
    worker.onerror = event => { clearTimeout(timer); reject(new Error(event.message)); };
    if (port.start) port.start();
  });
}

try {
  const results = {};
  results.secureContext = isSecureContext;
  results.module = value === 42;
  results.css = getComputedStyle(document.body).backgroundColor === 'rgb(12, 34, 56)';
  const context = document.querySelector('canvas').getContext('2d');
  context.fillStyle = '#00ff00'; context.fillRect(0, 0, 160, 90);
  results.canvas = context.getImageData(20, 20, 1, 1).data[1] === 255;
  results.fetch = (await (await fetch('./assets/value.json?query=ignored')).json()).value === 42;
  results.unicode = (await (await fetch('./assets/' + encodeURIComponent('中文 + %.json'))).json()).value === 42;
  results.insideLink = (await (await fetch('./inside.json')).json()).value === 42;
  results.outsideLink = (await fetch('./outside.txt')).status === 403;
  results.missing = (await fetch('./missing.json')).status === 403;
  const config = await (await fetch('./config.json')).json();
  results.network = await fetch(config.networkURL).then(() => false, () => true);
  results.fileURL = await fetch(config.outsideFileURL).then(() => false, () => true);
  const classic = new Worker('./classic-worker.js');
  results.classicWorker = (await resultFrom(classic)).value === 42; classic.terminate();
  const moduleWorker = new Worker('./module-worker.mjs', { type: 'module' });
  const moduleResult = await resultFrom(moduleWorker);
  results.moduleWorker = moduleResult.value === 42 && moduleResult.denied === true;
  moduleWorker.terminate();
  const shared = new SharedWorker('./shared-worker.js');
  results.sharedWorker = (await resultFrom(shared, shared.port)).value === 42;
  shared.port.close();
  const registration = await navigator.serviceWorker.register('./service-worker.js');
  await navigator.serviceWorker.ready;
  const channel = new MessageChannel();
  const serviceResult = resultFrom({}, channel.port1);
  registration.active.postMessage('check', [channel.port2]);
  const service = await serviceResult;
  results.serviceWorker = service.value === 42 && service.denied === true;
  results.serviceWorkerUnregistered = await registration.unregister();
  channel.port1.close();
  console.log('SOURCE_RESULT ' + JSON.stringify(results));
} catch (error) {
  console.error('SOURCE_FAILURE ' + error.stack);
}
