import { value } from './assets/value.mjs';
const denied = (await fetch('./outside.txt')).status === 403;
postMessage({ value, denied });
