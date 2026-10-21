const canvas = document.querySelector('canvas');
const context = canvas.getContext('2d');
if (!context) throw new Error('Dynamic mirror fixture requires a real 2D canvas');

function paint(now) {
  if (canvas.width !== innerWidth || canvas.height !== innerHeight) {
    canvas.width = innerWidth;
    canvas.height = innerHeight;
  }
  // The fixed green/blue channels identify the source; red changes every 125 ms.
  // No media element, AudioContext, worker or second browsing context is created.
  const phase = Math.floor(now / 125) % 64;
  context.fillStyle = `rgb(${32 + phase * 3}, 208, 24)`;
  context.fillRect(0, 0, canvas.width, canvas.height);
  requestAnimationFrame(paint);
}

requestAnimationFrame(paint);
