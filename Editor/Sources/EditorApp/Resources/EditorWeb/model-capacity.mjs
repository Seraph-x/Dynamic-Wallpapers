// Observe only this owned canvas/context. Never create a context ourselves or
// estimate a shader palette from device limits: shader linking can reduce it.
export function observeModelCapacity(canvas) {
  const restore=[],contexts=new Set();let capacity,error,disposed=false;
  function intercept(target,key,wrap) {
    const descriptor=Object.getOwnPropertyDescriptor(target,key),original=target[key],hook=wrap(original);
    Object.defineProperty(target,key,{value:hook,configurable:true,writable:true,enumerable:descriptor?.enumerable??false});
    restore.push(()=>{if(target[key]===hook){if(descriptor)Object.defineProperty(target,key,descriptor);else delete target[key];}});
  }
  function observe(gl) {
    if(contexts.has(gl))return;contexts.add(gl);const seen=new Set();
    function inspect() {
      if(capacity!==undefined || error || disposed)return;
      try {
        const program=gl.getParameter(gl.CURRENT_PROGRAM);
        if(!program || seen.has(program))return;seen.add(program);
        const count=gl.getProgramParameter(program,gl.ACTIVE_UNIFORMS);
        for(let i=0;i<count;i++){
          const uniform=gl.getActiveUniform(program,i);
          if(uniform?.name!=='u_skin[0]')continue;
          if(!Number.isInteger(uniform.size) || uniform.size<1 || uniform.size>128)throw new Error('Unexpected linked model palette capacity');
          capacity=uniform.size;break;
        }
      }catch(value){error=value instanceof Error?value:new Error(String(value));capacity=undefined;}
    }
    for(const key of ['drawElements','drawArrays'])intercept(gl,key,original=>function(...args){
      const result=Reflect.apply(original,this,args);inspect();return result;
    });
  }
  intercept(canvas,'getContext',original=>function(type,...args){
    const gl=Reflect.apply(original,this,[type,...args]);
    if(type==='webgl2' && gl && !disposed)observe(gl);
    return gl;
  });
  return {get capacity(){return capacity;},get error(){return error;},dispose(){
    if(disposed)return;disposed=true;for(const cleanup of restore.reverse())cleanup();contexts.clear();
  }};
}
