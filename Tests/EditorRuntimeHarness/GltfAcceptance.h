#pragma once
#include <cstring>

// All scripting below belongs to this test executable. Confirmation still uses
// a trusted CEF keyboard event and pixels come from actual engine draw calls.
@interface DWWebPage (GltfAcceptance)
- (NSDictionary*)gltfTestAwait:(NSString*)expression;
- (void)gltfTestReturn;
- (void)gltfTestEscape;
- (void)gltfTestKey:(NSString*)character code:(unsigned short)code;
@end
@implementation DWWebPage (GltfAcceptance)
- (NSDictionary*)gltfTestAwait:(NSString*)expression {
  __block BOOL done=NO;__block NSDictionary* result=nil;__block NSError* failure=nil;
  NSString* identifier=NSUUID.UUID.UUIDString;
  _editorCompletions[identifier]=^(NSDictionary* reply,NSError* error){result=reply;failure=error;done=YES;};
  _editorDeadlines[identifier]=@(NSProcessInfo.processInfo.systemUptime+5);
  NSDictionary* event=@{@"type":@"reply",@"id":identifier,@"session":@(_resources->state->editor->session.c_str()),@"generation":@1};
  NSString* json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] encoding:NSUTF8StringEncoding];
  [self editorTestScript:[NSString stringWithFormat:@"(()=>{const event=%@;const send=payload=>fetch('/__editor/event',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...event,payload})});const check=()=>{try{const value=(%@);if(value)void send({value});else requestAnimationFrame(check);}catch(error){void send({error:String(error)});}};check();})();",json,expression]];
  waitUntil(^{return done;},6,"Native glTF renderer assertion timed out");
  if(failure||!result||result[@"error"])fprintf(stderr,"Native glTF failed renderer assertion: %s\n",expression.UTF8String);
  require(!failure,failure.localizedDescription.UTF8String ?: "Native glTF assertion transport failed");
  require(result!=nil&&!result[@"error"],[result[@"error"] UTF8String] ?: "Native glTF assertion failed");return result;
}
- (void)gltfTestReturn {
  [self gltfTestKey:@"\r" code:36];
}
- (void)gltfTestEscape {
  fprintf(stderr,"Native glTF keyboard Escape\n");
  [self gltfTestKey:@"\033" code:53];
}
- (void)gltfTestKey:(NSString*)character code:(unsigned short)code {
  // Synthetic AppKit events must release their native view/window references
  // before the browser close handshake, matching editorTestType's lifetime.
  @autoreleasepool {
  _resources->state->browser->GetHost()->SetFocus(true);
  NSView* child=(__bridge NSView*)_resources->state->browser->GetHost()->GetWindowHandle();
  for(const NSEventType type:{NSEventTypeKeyDown,NSEventTypeKeyUp}){
    NSEvent* event=[NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
      windowNumber:child.window.windowNumber context:nil characters:character charactersIgnoringModifiers:character isARepeat:NO keyCode:code];
    [NSApp sendEvent:event];
  }
  }
}
@end

static NSDictionary* gltfCommand(DWWebPage* page,NSDictionary* payload) {
  fprintf(stderr,"Native glTF command begin=%s\n",[payload[@"type"] UTF8String]);
  NSDictionary* result=command(page,payload);
  fprintf(stderr,"Native glTF command end=%s\n",[payload[@"type"] UTF8String]);return result;
}
static NSDictionary* gltfJSON(NSString* path) {
  NSError* error=nil;NSData* bytes=[NSData dataWithContentsOfFile:path options:0 error:&error];
  require(bytes!=nil,error.localizedDescription.UTF8String ?: "Native glTF fixture missing");
  id value=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:&error];
  require([value isKindOfClass:NSDictionary.class],error.localizedDescription.UTF8String ?: "Native glTF fixture is not an object");return value;
}
static uint32_t gltfU32(NSData* bytes,NSUInteger offset) {
  require(offset<=bytes.length&&bytes.length-offset>=sizeof(uint32_t),"Native glTF MDL integer is out of bounds");
  uint32_t value=0;[bytes getBytes:&value range:NSMakeRange(offset,sizeof(value))];return CFSwapInt32LittleToHost(value);
}
static NSUInteger gltfSection(NSData* bytes,NSString* name) {
  NSData* signature=[name dataUsingEncoding:NSASCIIStringEncoding];
  const NSRange result=[bytes rangeOfData:signature options:0 range:NSMakeRange(0,bytes.length)];
  require(result.location!=NSNotFound,"Native glTF MDL section missing");return result.location;
}
static void verifyGltfMDL(NSData* bytes) {
  require(bytes.length>21&&std::memcmp(bytes.bytes,"MDLV0023",8)==0,"Native glTF resource is not an actual MDLV0023 model");
  require(gltfU32(bytes,17)==2,"Native glTF material meshes were not preserved");
  require(gltfU32(bytes,gltfSection(bytes,@"MDLS0004")+13)==4,"Native glTF hierarchy was not preserved");
  const NSUInteger animation=gltfSection(bytes,@"MDLA0006");require(gltfU32(bytes,animation+13)==1,"Native glTF animation missing");
  NSUInteger cursor=animation+25;const auto* data=static_cast<const unsigned char*>(bytes.bytes);
  for(int field=0;field<2;++field){while(cursor<bytes.length&&data[cursor])++cursor;require(cursor<bytes.length,"Native glTF clip string is truncated");++cursor;}
  const uint32_t encodedFPS=gltfU32(bytes,cursor);float fps=0;std::memcpy(&fps,&encodedFPS,sizeof(fps));
  require(fps==30&&gltfU32(bytes,cursor+4)==12,"Native glTF 0.37s/30fps animation was not baked to twelve frames");
}
static void expectGltfPending(DWWebPage* page) {
  fprintf(stderr,"Native glTF pending snapshot begin\n");
  __block BOOL done=NO;__block NSDictionary* reply=nil;__block NSError* failure=nil;
  [page requestEditorCommand:@{@"type":@"snapshot"} completion:^(NSDictionary* result,NSError* error){reply=result;failure=error;done=YES;}];
  waitUntil(^{return done;},6,"Native glTF pending snapshot did not respond");
  require(!failure&&[reply[@"error"] containsString:@"Finish or cancel model import"],"Native glTF dialog did not enforce its snapshot barrier");
  fprintf(stderr,"Native glTF pending snapshot end\n");
}
static void verifyGltfWorkbench(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,NSString* resources,NSString* sourcePath) {
  NSDictionary* source=gltfJSON(sourcePath),*original=@{@"title":@"Native glTF",@"entry":@"scene.json",
    @"project":gltfJSON([projectRoot stringByAppendingPathComponent:@"project.json"]),@"scene":gltfJSON([projectRoot stringByAppendingPathComponent:@"scene.json"])};
  require([original[@"scene"][@"objects"] count]==0,"Native glTF source scene must start empty");
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native glTF workbench creation failed");
  page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});
  NSWindow* window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1180,760) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;page.view.frame=window.contentView.bounds;[window.contentView addSubview:page.view];[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native glTF first frame timed out");require(!failure,"Native glTF workbench failed");
  require([page editorTestNativeViewIsAttached],"Native glTF CEF child is detached");gltfCommand(page,@{@"type":@"thaw"});
  gltfCommand(page,@{@"type":@"import-model",@"source":source});expectGltfPending(page);
  [page gltfTestAwait:@"(()=>{window.__gltfTrustedEscape=false;document.addEventListener('keydown',event=>{if(event.key==='Escape')window.__gltfTrustedEscape=event.isTrusted;},{once:true});return true;})()"];
  [page gltfTestEscape];[page gltfTestAwait:@"!document.getElementById('gltf-dialog').open&&window.__gltfTrustedEscape"];
  require([gltfCommand(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native glTF Escape published content");
  gltfCommand(page,@{@"type":@"import-model",@"source":source});
  [page editorTestScript:@"document.getElementById('gltf-name').focus();document.getElementById('gltf-name').select();"];
  [page editorTestAwaitInput:@"#gltf-name" value:@"model" focused:YES];[page editorTestType:@"Native imported rig"];
  [page editorTestAwaitInput:@"#gltf-name" value:@"Native imported rig"];
  [page editorTestScript:@"const mode=document.getElementById('gltf-mode');mode.value='single';mode.dispatchEvent(new Event('input',{bubbles:true}));document.getElementById('gltf-update').click();"];
  [page gltfTestAwait:@"!document.getElementById('gltf-confirm').disabled&&document.getElementById('gltf-error').textContent===''&&document.getElementById('gltf-stats').textContent.endsWith('2 / 4 / 1')"];
  [page editorTestScript:@"window.__gltfTrustedConfirm=false;const confirm=document.getElementById('gltf-confirm');confirm.addEventListener('click',event=>{window.__gltfTrustedConfirm=event.isTrusted;},{once:true});confirm.focus();"];
  [page gltfTestAwait:@"document.activeElement===document.getElementById('gltf-confirm')"];[page gltfTestReturn];
  [page gltfTestAwait:@"!document.getElementById('gltf-dialog').open&&window.__gltfTrustedConfirm&&document.getElementById('model-bone-name').value==='Root'"];
  NSDictionary* frozen=gltfCommand(page,@{@"type":@"freeze"}),*saved=frozen[@"document"],*overrides=saved[@"resourceOverrides"];
  require([frozen[@"dirty"] boolValue]&&[saved[@"scene"][@"objects"] count]==1,"Native glTF import did not add exactly one model layer");
  NSDictionary* layer=saved[@"scene"][@"objects"][0];NSString* mdlPath=layer[@"model"];
  require([layer[@"name"] isEqual:@"Native imported rig"]&&[mdlPath hasSuffix:@".mdl"],"Native glTF typed layer name or MDL binding missing");
  for(NSString* path in overrides){NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:overrides[path]]];require(bytes!=nil&&[resourceHash(bytes) isEqual:overrides[path]],"Native glTF staged resource hash mismatch");}
  verifyGltfMDL([NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:overrides[mdlPath]]]);
  for(NSDictionary* file in source[@"files"]){
    NSString* suffix=[@"/source/" stringByAppendingString:file[@"path"]],*archived=nil;
    for(NSString* path in overrides)if([path hasSuffix:suffix]){require(archived==nil,"Native glTF source archive is ambiguous");archived=path;}
    require(archived!=nil,"Native glTF source asset was not archived");
    NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:overrides[archived]]],*expected=[[NSData alloc]initWithBase64EncodedString:file[@"data"] options:0];
    require([bytes isEqualToData:expected],"Native glTF archive changed original source bytes");
  }
  gltfCommand(page,@{@"type":@"mark-saved",@"document":saved});require(![gltfCommand(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native glTF saved acknowledgement stayed dirty");
  gltfCommand(page,@{@"type":@"thaw"});gltfCommand(page,@{@"type":@"undo"});require([gltfCommand(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native glTF import undo was not one atomic revision");
  gltfCommand(page,@{@"type":@"redo"});require([gltfCommand(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native glTF import redo lost resources or layer");
  [page gltfTestAwait:@"(()=>{const playback=document.getElementById('playback');if(playback.getAttribute('aria-pressed')==='true')playback.click();return playback.getAttribute('aria-pressed')==='false';})()"];
  // Observe pixels immediately after actual draw calls, before a non-preserved
  // WebGL drawing buffer may be cleared by the compositor.
  [page gltfTestAwait:@"(()=>{const canvas=document.querySelector('#canvas canvas'),gl=canvas.getContext('webgl2');window.__gltfSeekPixels=null;window.__gltfRestore=[];for(const name of ['drawElements','drawArrays']){const original=gl[name];window.__gltfRestore.push(()=>gl[name]=original);gl[name]=function(...args){const result=original.apply(this,args),bytes=new Uint8Array(canvas.width*canvas.height*4),counts=[0,0],xs=[0,0],ys=[0,0];gl.readPixels(0,0,canvas.width,canvas.height,gl.RGBA,gl.UNSIGNED_BYTE,bytes);for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){const at=(y*canvas.width+x)*4,r=bytes[at],g=bytes[at+1],b=bytes[at+2],color=r<70&&g>180&&b<70?0:r<70&&g<70&&b>180?1:-1;if(color>=0){counts[color]++;xs[color]+=x;ys[color]+=y;}}if(counts.every(value=>value>100)){const scale=(xs[1]/counts[1]-xs[0]/counts[0])/70;window.__gltfSeekPixels={displacement:(ys[1]/counts[1]-ys[0]/counts[0])/scale,scale};}return result;};}return true;})()"];
  require(std::abs([gltfCommand(page,@{@"type":@"seek",@"time":@.2})[@"time"] doubleValue]-.2)<1e-8,"Native glTF seek did not acknowledge 0.2s");
  NSDictionary* pose=[page gltfTestAwait:@"window.__gltfSeekPixels"][@"value"];
  require([pose[@"scale"] doubleValue]>0&&std::abs([pose[@"displacement"] doubleValue]-60*.2/.37)<1.5,"Native glTF actual engine pose at 0.2s is incorrect");
  fprintf(stderr,"Native glTF engine seek: time=0.2s displacement=%.3f expected=%.3f px\n",[pose[@"displacement"] doubleValue],60*.2/.37);
  [page editorTestScript:@"for(const restore of window.__gltfRestore)restore();delete window.__gltfRestore;delete window.__gltfSeekPixels;"];
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];
  waitUntil(^{return released;},7,"Native glTF editor close timed out");require(!failure&&page.closed&&runtime.activePageCount==0,"Native glTF editor resources were not released");[window close];
  fprintf(stderr,"Native glTF: actual preview, trusted keyboard confirmation, exact MDL/archive hashes, save, atomic history and 0.2s pose passed\n");
}
static NSArray* gltfPixels(DWWebPage* page) {
  CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;if(!image)return @[];
  NSData* data=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));require(data!=nil,"Native glTF Main pixel read failed");
  const auto* bytes=static_cast<const UInt8*>(data.bytes);const size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),row=CGImageGetBytesPerRow(image);
  size_t count[2]={0,0};double xs[2]={0,0},ys[2]={0,0};
  for(size_t y=0;y<height;++y)for(size_t x=0;x<width;++x){const size_t at=y*row+x*4;const auto b=bytes[at],g=bytes[at+1],r=bytes[at+2];
    const int color=r<70&&g>180&&b<70?0:r<70&&g<70&&b>180?1:-1;if(color>=0){++count[color];xs[color]+=x;ys[color]+=y;}}
  return @[@(count[0]),@(count[1]),@(count[0]?xs[0]/count[0]:0),@(count[1]?xs[1]/count[1]:0),@(count[0]?ys[0]/count[0]:0),@(count[1]?ys[1]/count[1]:0)];
}
static void verifyGltfExport(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,BOOL package) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native glTF Main page creation failed");page.onError=^(NSError* value){failure=value;};[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Native glTF Main first frame timed out");require(!failure,"Native glTF Main rendering failed");
  __block double low=1e9,high=-1e9;
  waitUntil(^{NSArray* p=gltfPixels(page);if(p.count!=6||[p[0] unsignedLongValue]<200||[p[1] unsignedLongValue]<200)return NO;
    require(std::abs([p[2] doubleValue]-284.5)<2&&std::abs([p[3] doubleValue]-354.5)<2,"Native glTF Main changed material separation or bind X placement");
    require(std::abs([p[4] doubleValue]-179.5)<2,"Native glTF Main moved the stationary green mesh");
    const double displacement=[p[4] doubleValue]-[p[5] doubleValue];require(displacement>=-2&&displacement<=62,"Native glTF Main motion exceeded source range");
    low=std::min(low,displacement);high=std::max(high,displacement);return BOOL(high-low>8&&std::abs(displacement-60*.2/.37)<3);
  },3,"Native glTF Main did not render known intermediate motion");require(!failure,"Native glTF Main export reported an error");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native glTF Main close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native glTF Main page resources were not released");
  fprintf(stderr,"Main glTF %s: separate green/blue materials, fixed bind and known intermediate motion %.2f..%.2f px passed\n",package?"PKG":"loose",low,high);
}
