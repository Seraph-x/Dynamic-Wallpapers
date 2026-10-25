#pragma once
#include <cstring>

// Test-only assertions use the production CEF command transport. Keyboard input
// goes through AppKit so dialog confirmation and focused drafts are trusted.
@interface DWWebPage (ClipAcceptance)
- (NSDictionary*)clipTestAwait:(NSString*)expression;
- (void)clipTestKey:(NSString*)character code:(unsigned short)code;
@end
@implementation DWWebPage (ClipAcceptance)
- (NSDictionary*)clipTestAwait:(NSString*)expression {
  __block BOOL done=NO;__block NSDictionary* result=nil;__block NSError* failure=nil;
  NSString* identifier=NSUUID.UUID.UUIDString;
  _editorCompletions[identifier]=^(NSDictionary* reply,NSError* error){result=reply;failure=error;done=YES;};
  _editorDeadlines[identifier]=@(NSProcessInfo.processInfo.systemUptime+5);
  NSDictionary* event=@{@"type":@"reply",@"id":identifier,@"session":@(_resources->state->editor->session.c_str()),@"generation":@1};
  NSString* json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] encoding:NSUTF8StringEncoding];
  [self editorTestScript:[NSString stringWithFormat:@"(()=>{const event=%@;const send=payload=>fetch('/__editor/event',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...event,payload})});const check=()=>{try{const value=(%@);if(value)void send({value});else requestAnimationFrame(check);}catch(error){void send({error:String(error)});}};check();})();",json,expression]];
  waitUntil(^{return done;},6,"Native clip renderer assertion timed out");
  if(failure||!result||result[@"error"])fprintf(stderr,"Native clip failed renderer assertion: %s\n",expression.UTF8String);
  require(!failure,failure.localizedDescription.UTF8String ?: "Native clip assertion transport failed");
  require(result!=nil&&!result[@"error"],[result[@"error"] UTF8String] ?: "Native clip assertion failed");return result;
}
- (void)clipTestKey:(NSString*)character code:(unsigned short)code {
  // These events retain the native window. Release them before CEF's close
  // handshake; an outer main autorelease pool outlives runtime shutdown.
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

static NSDictionary* clipJSON(NSString* path) {
  NSError* error=nil;NSData* bytes=[NSData dataWithContentsOfFile:path options:0 error:&error];
  require(bytes!=nil,error.localizedDescription.UTF8String ?: "Native clip fixture missing");
  id value=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:&error];
  require([value isKindOfClass:NSDictionary.class],error.localizedDescription.UTF8String ?: "Native clip fixture is not an object");return value;
}
static uint32_t clipU32(NSData* bytes,NSUInteger offset) {
  require(offset<=bytes.length&&bytes.length-offset>=sizeof(uint32_t),"Native clip MDL integer is out of bounds");
  uint32_t value=0;[bytes getBytes:&value range:NSMakeRange(offset,sizeof(value))];return CFSwapInt32LittleToHost(value);
}
static NSUInteger clipSection(NSData* bytes,NSString* name) {
  const NSRange found=[bytes rangeOfData:[name dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0,bytes.length)];
  require(found.location!=NSNotFound,"Native clip MDL section missing");return found.location;
}
static void verifyClipMDL(NSData* bytes,NSData* original) {
  require(bytes.length>21&&std::memcmp(bytes.bytes,"MDLV0023",8)==0,"Native clip resource is not an actual MDLV0023 model");
  require(clipU32(bytes,clipSection(bytes,@"MDLA0006")+13)==3,"Native clip edit changed the three-clip library");
  const char name[]="Native Clip";NSData* signature=[NSData dataWithBytes:name length:sizeof(name)];
  const NSRange found=[bytes rangeOfData:signature options:0 range:NSMakeRange(0,bytes.length)];
  require(found.location!=NSNotFound&&found.location>=8,"Native typed clip name did not reach the actual MDL");
  require(clipU32(bytes,found.location-8)==2,"Native edit changed the selected clip ID");
  NSUInteger cursor=found.location+signature.length;const auto* data=static_cast<const unsigned char*>(bytes.bytes);
  while(cursor<bytes.length&&data[cursor])++cursor;require(cursor<bytes.length,"Native clip playback mode is truncated");++cursor;
  const uint32_t encodedFPS=clipU32(bytes,cursor);float fps=0;std::memcpy(&fps,&encodedFPS,sizeof(fps));
  require(fps==8&&clipU32(bytes,cursor+4)==4,"Native focused FPS did not retain the four-frame clip");
  const NSUInteger bind=clipSection(bytes,@"MDLS0004"),originalBind=clipSection(original,@"MDLS0004");
  const NSUInteger end=clipU32(bytes,bind+9),originalEnd=clipU32(original,originalBind+9);
  require(end>=bind&&end<=bytes.length&&originalEnd>=originalBind&&originalEnd<=original.length,"Native clip bind section is out of bounds");
  require([[bytes subdataWithRange:NSMakeRange(bind,end-bind)] isEqualToData:[original subdataWithRange:NSMakeRange(originalBind,originalEnd-originalBind)]],"Native clip editing changed skeleton metadata or bind matrices");
}
static void expectClipPending(DWWebPage* page) {
  __block BOOL done=NO;__block NSDictionary* reply=nil;__block NSError* failure=nil;
  [page requestEditorCommand:@{@"type":@"snapshot"} completion:^(NSDictionary* result,NSError* error){reply=result;failure=error;done=YES;}];
  waitUntil(^{return done;},6,"Native clip pending snapshot did not respond");
  require(!failure&&[reply[@"error"] containsString:@"Finish or cancel"],"Native clip dialog did not enforce its snapshot barrier");
}
static void verifyClipWorkbench(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,NSString* resources) {
  NSDictionary* original=@{@"title":@"Native clips",@"entry":@"scene.json",@"project":clipJSON([projectRoot stringByAppendingPathComponent:@"project.json"]),@"scene":clipJSON([projectRoot stringByAppendingPathComponent:@"scene.json"])};
  NSArray* objects=original[@"scene"][@"objects"];
  require(objects.count==1&&[objects[0][@"animationlayers"][0][@"animation"] isEqual:@2],"Native clip export must explicitly assign the authored duplicate");
  NSString* modelPath=@"models/editor/rig.mdl";NSData* originalBytes=[NSData dataWithContentsOfFile:[projectRoot stringByAppendingPathComponent:modelPath]];
  require(originalBytes!=nil,"Native clip exported MDL is missing");
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native clip workbench creation failed");
  page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});
  NSWindow* window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1180,760) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;page.view.frame=window.contentView.bounds;[window.contentView addSubview:page.view];[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native clip first frame timed out");require(!failure,"Native clip workbench failed");
  require([page editorTestNativeViewIsAttached],"Native clip CEF child is detached");command(page,@{@"type":@"thaw"});
  [page editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"1\"]').click();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"document.getElementById('model-workspace').click();"];command(page,@{@"type":@"snapshot"});
  [page clipTestAwait:@"document.getElementById('model-clip-select').options.length===3&&!document.getElementById('model-clip-create').disabled"];
  [page editorTestScript:@"document.getElementById('model-clips-details').open=true;document.getElementById('model-clip-create').click();"];
  [page clipTestAwait:@"document.getElementById('model-clip-create-dialog').open"];expectClipPending(page);
  [page clipTestAwait:@"(()=>{window.__clipTrustedEscape=false;document.addEventListener('keydown',event=>{if(event.key==='Escape')window.__clipTrustedEscape=event.isTrusted;},{once:true});return true;})()"];
  [page clipTestKey:@"\033" code:53];[page clipTestAwait:@"!document.getElementById('model-clip-create-dialog').open&&window.__clipTrustedEscape"];
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native clip trusted cancellation published content");
  [page editorTestScript:@"const select=document.getElementById('model-clip-select');select.value='2';select.dispatchEvent(new Event('change',{bubbles:true}));"];
  [page clipTestAwait:@"document.getElementById('model-clip-select').value==='2'&&document.getElementById('model-clip-fps').value==='4'&&!document.getElementById('model-clip-name').disabled"];
  fprintf(stderr,"Native clips phase=name-focus\n");
  [page editorTestScript:@"(()=>{const input=document.getElementById('model-clip-name');input.scrollIntoView({block:'center'});input.focus();input.select();window.__clipTypedTrusted=false;input.addEventListener('input',event=>{window.__clipTypedTrusted=event.isTrusted;},{once:true});})();"];
  [page clipTestAwait:@"document.activeElement===document.getElementById('model-clip-name')"];fprintf(stderr,"Native clips phase=name-type\n");[page editorTestType:@"Native Clip"];
  [page editorTestAwaitInput:@"#model-clip-name" value:@"Native Clip"];[page clipTestAwait:@"window.__clipTypedTrusted"];
  fprintf(stderr,"Native clips phase=fps-focus\n");
  [page editorTestScript:@"(()=>{const input=document.getElementById('model-clip-fps');input.focus();input.select();})();"];
  [page editorTestAwaitInput:@"#model-clip-fps" value:@"4" focused:YES];fprintf(stderr,"Native clips phase=fps-type\n");[page editorTestType:@"8"];
  [page editorTestAwaitInput:@"#model-clip-fps" value:@"8" focused:YES];
  fprintf(stderr,"Native clips phase=focused-freeze\n");
  NSDictionary* frozen=command(page,@{@"type":@"freeze"}),*saved=frozen[@"document"];
  NSString* version=saved[@"resourceOverrides"][modelPath];
  require(version.length==64&&[frozen[@"dirty"] boolValue],"Native clip focused input was not published before freeze");
  require([saved[@"scene"] isEqual:original[@"scene"]]&&[saved[@"resourceOverrides"] count]==1,"Native clip resource edit rewrote scene playback or unrelated resources");
  NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:version]];
  require(bytes!=nil&&[resourceHash(bytes) isEqual:version],"Native clip MDL hash mismatch");verifyClipMDL(bytes,originalBytes);
  fprintf(stderr,"Native clips phase=save-and-atomic-history\n");
  command(page,@{@"type":@"mark-saved",@"document":saved});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native clip save acknowledgement remained dirty");
  command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native clip name/FPS undo was not one atomic resource revision");
  command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native clip redo lost authored bytes or native assignment");
  fprintf(stderr,"Native clips phase=trusted-playback-default\n");
  [page editorTestScript:@"document.getElementById('model-clip-default').click();"];
  [page clipTestAwait:@"document.getElementById('model-clip-playback-dialog').open"];
  [page clipTestAwait:@"(()=>{window.__clipTrustedConfirm=false;const button=document.getElementById('model-clip-playback-dialog-confirm');button.addEventListener('click',event=>{window.__clipTrustedConfirm=event.isTrusted;},{once:true});button.focus();return document.activeElement===button;})()"];
  [page clipTestKey:@"\r" code:36];[page clipTestAwait:@"!document.getElementById('model-clip-playback-dialog').open&&window.__clipTrustedConfirm"];
  NSDictionary* defaulted=command(page,@{@"type":@"snapshot"})[@"document"];
  require(defaulted[@"scene"][@"objects"][0][@"animationlayers"]==nil,"Native trusted default playback did not remove animationlayers");
  require([defaulted[@"resourceOverrides"] isEqual:saved[@"resourceOverrides"]],"Native playback assignment unexpectedly rewrote MDL bytes");
  command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native playback undo did not restore the exact prior native table");
  fprintf(stderr,"Native clips phase=actual-authored-pose\n");
  // Read pixels directly after actual engine draw calls, while the WebGL buffer
  // still contains the frame. Mesh separation supplies the actual canvas scale.
  [page clipTestAwait:@"(()=>{const playback=document.getElementById('playback');if(playback.getAttribute('aria-pressed')==='true')playback.click();return playback.getAttribute('aria-pressed')==='false';})()"];
  [page clipTestAwait:@"(()=>{const canvas=document.querySelector('#canvas canvas'),gl=canvas.getContext('webgl2');window.__clipPose=null;window.__clipRestore=[];for(const name of ['drawElements','drawArrays']){const original=gl[name];window.__clipRestore.push(()=>gl[name]=original);gl[name]=function(...args){const result=original.apply(this,args),bytes=new Uint8Array(canvas.width*canvas.height*4),counts=[0,0],xs=[0,0],ys=[0,0];gl.readPixels(0,0,canvas.width,canvas.height,gl.RGBA,gl.UNSIGNED_BYTE,bytes);for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){const at=(y*canvas.width+x)*4;if(bytes[at]<70&&bytes[at+1]>180&&bytes[at+2]<70){const half=x<canvas.width/2?0:1;counts[half]++;xs[half]+=x;ys[half]+=y;}}if(counts.every(n=>n>100)){const scale=(xs[1]/counts[1]-xs[0]/counts[0])/70;window.__clipPose={displacement:(ys[1]/counts[1]-ys[0]/counts[0])/scale,scale};}return result;};}return true;})()"];
  require(std::abs([command(page,@{@"type":@"seek",@"time":@.25})[@"time"] doubleValue]-.25)<1e-8,"Native clip seek did not acknowledge 0.25s");
  NSDictionary* pose=[page clipTestAwait:@"window.__clipPose"][@"value"];
  require([pose[@"scale"] doubleValue]>0&&std::abs([pose[@"displacement"] doubleValue]-30)<1.5,"Native authored 8fps/four-frame clip did not render 30px displacement at 0.25s");
  [page editorTestScript:@"for(const restore of window.__clipRestore)restore();delete window.__clipRestore;delete window.__clipPose;"];
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native clip editor close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native clip editor resources were not released");[window close];
  fprintf(stderr,"Native clips: trusted cancellation/assignment, focused typed name/FPS freeze, MDL/hash, save, atomic history and exact 0.25s pose passed\n");
}
static void verifyClipExport(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,BOOL package,BOOL stationary=NO) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native clip Main page creation failed");page.onError=^(NSError* value){failure=value;};[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Native clip Main first frame timed out");require(!failure,"Native clip Main rendering failed");
  __block double low=1e9,high=-1e9,staticStart=-1;__block NSUInteger samples=0;
  waitUntil(^{NSArray* p=modelPixels(page);if([p[0] unsignedLongValue]<100||[p[1] unsignedLongValue]<100)return NO;
    require(std::abs([p[2] doubleValue]-284.5)<2&&std::abs([p[3] doubleValue]-354.5)<2,"Native clip Main changed horizontal bind placement");
    require(std::abs([p[4] doubleValue]-179.5)<2,"Native clip Main moved the stationary mesh");
    const double displacement=[p[4] doubleValue]-[p[5] doubleValue];require(displacement>=-2&&displacement<=62,"Native clip Main motion exceeded authored range");
    low=std::min(low,displacement);high=std::max(high,displacement);
    if(stationary){
      require(std::abs([p[5] doubleValue]-179.5)<2,"Native empty clip library did not render the actual right bind pose");
      // Check the first actual CEF image and every sampled image while running
      // the real native event loop for at least half a second after that frame.
      const double now=NSProcessInfo.processInfo.systemUptime;if(staticStart<0)staticStart=now;++samples;
      return BOOL(samples>1&&now-staticStart>=.5);
    }
    return BOOL(high-low>10&&std::abs(displacement-30)<3);
  },3,stationary?"Native empty clip library did not retain both actual bind meshes across later frames":"Native clip Main did not render its known 30px intermediate motion");require(!failure,"Native clip Main reported an error");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native clip Main close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native clip Main resources were not released");
  if(stationary)fprintf(stderr,"Main clip %s: empty library held both actual bind meshes for >=0.5s (%lu samples, %.2f..%.2f px) passed\n",package?"PKG":"loose",static_cast<unsigned long>(samples),low,high);
  else fprintf(stderr,"Main clip %s: explicit authored clip, stationary bind and known 30px intermediate motion %.2f..%.2f px passed\n",package?"PKG":"loose",low,high);
}
