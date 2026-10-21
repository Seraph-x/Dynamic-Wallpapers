const canvas = document.querySelector('canvas');
const context = canvas.getContext('2d');
context.fillStyle = '#00ff00'; context.fillRect(0, 0, canvas.width, canvas.height);
const worker = new Worker('worker.js');
worker.onmessage = event => console.log('WEB_WORKER', event.data);
