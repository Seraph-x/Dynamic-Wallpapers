onconnect = async event => {
  const value = await (await fetch('./assets/value.json?shared-worker')).json();
  event.ports[0].postMessage(value);
};
