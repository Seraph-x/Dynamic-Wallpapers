export async function eventPixels(page){
 const image=await page.locator('#canvas canvas').screenshot();
 return page.evaluate(async image=>{
  const bitmap=await createImageBitmap(new Blob([new Uint8Array(image)],{type:'image/png'})),canvas=document.createElement('canvas');canvas.width=bitmap.width;canvas.height=bitmap.height;
  const ctx=canvas.getContext('2d');ctx.drawImage(bitmap,0,0);bitmap.close();const data=ctx.getImageData(0,0,canvas.width,canvas.height).data;
  const green=[0,0],red=[0,0];for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){const i=(y*canvas.width+x)*4,half=x<canvas.width/2?0:1;if(data[i]<70&&data[i+1]>180&&data[i+2]<70)green[half]++;if(data[i]>180&&data[i+1]<70&&data[i+2]<70)red[half]++;}
  return {green,red};
 },[...image]);
}
