// Read the decoded texture attachment directly. Canvas2D premultiplication loses
// RGB at alpha=0, which glTF OPAQUE materials must still display.
export function gltfImagePixels(bitmap){
 const canvas=document.createElement('canvas'),gl=canvas.getContext('webgl2',{premultipliedAlpha:false});if(!gl)throw new Error('Lossless glTF texture conversion requires WebGL2');
 let texture,framebuffer;
 try{
  texture=gl.createTexture();framebuffer=gl.createFramebuffer();if(!texture||!framebuffer)throw new Error('Cannot allocate glTF texture readback');
  gl.bindTexture(gl.TEXTURE_2D,texture);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,bitmap);
  gl.bindFramebuffer(gl.FRAMEBUFFER,framebuffer);gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,texture,0);
  if(gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE)throw new Error('Incomplete glTF texture readback framebuffer');
  const pixels=new Uint8Array(bitmap.width*bitmap.height*4);gl.readPixels(0,0,bitmap.width,bitmap.height,gl.RGBA,gl.UNSIGNED_BYTE,pixels);
  const error=gl.getError();if(error!==gl.NO_ERROR)throw new Error(`glTF texture readback failed: WebGL ${error}`);return pixels;
 }finally{if(framebuffer)gl.deleteFramebuffer(framebuffer);if(texture)gl.deleteTexture(texture);gl.getExtension('WEBGL_lose_context')?.loseContext();}
}
