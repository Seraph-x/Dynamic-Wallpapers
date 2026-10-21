self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('message', event => event.waitUntil((async () => {
  const value = await (await fetch('./assets/value.json?service-worker')).json();
  const denied = (await fetch('./outside.txt')).status === 403;
  event.ports[0].postMessage({ value: value.value, denied });
})()));
