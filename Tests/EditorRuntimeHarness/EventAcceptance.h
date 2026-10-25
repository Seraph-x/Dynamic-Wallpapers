#pragma once

// Main's committed native image is BGRA; count actual red and green separately.
static NSDictionary* eventPixels(DWWebPage* page) {
  CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;
  if(!image)return @{@"green":@[@0,@0],@"red":@[@0,@0],@"count":@[@0,@0],@"x":@[@0,@0],@"y":@[@0,@0]};
  NSData* data=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));require(data!=nil,"Native event pixel read failed");
  const auto* bytes=static_cast<const UInt8*>(data.bytes);
  const size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),rowBytes=CGImageGetBytesPerRow(image);
  size_t green[2]={0,0},red[2]={0,0},count[2]={0,0};double xs[2]={0,0},ys[2]={0,0};
  for(size_t y=0;y<height;++y)for(size_t x=0;x<width;++x){
    const size_t at=y*rowBytes+x*4,half=x<width/2?0:1;
    const bool isGreen=bytes[at]<70&&bytes[at+1]>180&&bytes[at+2]<70,isRed=bytes[at]<70&&bytes[at+1]<70&&bytes[at+2]>180;
    if(isGreen)++green[half];if(isRed)++red[half];if(isGreen||isRed){++count[half];xs[half]+=x;ys[half]+=y;}
  }
  return @{@"green":@[@(green[0]),@(green[1])],@"red":@[@(red[0]),@(red[1])],@"count":@[@(count[0]),@(count[1])],
    @"x":@[@(count[0]?xs[0]/count[0]:0),@(count[1]?xs[1]/count[1]:0)],@"y":@[@(count[0]?ys[0]/count[0]:0),@(count[1]?ys[1]/count[1]:0)]};
}

static void verifyEventStationary(NSDictionary* initial,NSDictionary* actual) {
  const double scale=([initial[@"x"][1] doubleValue]-[initial[@"x"][0] doubleValue])/70;
  require(scale>0,"Native event meshes did not retain their known horizontal separation");
  for(NSUInteger half=0;half<2;++half)for(NSString* axis in @[@"x",@"y"])
    require(std::abs([actual[axis][half] doubleValue]-[initial[axis][half] doubleValue])/scale<1.5,"Native event callback changed stationary mesh placement");
}

static void verifyEventWorkbench(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,NSString* resources,NSString* expectedPath) {
  NSDictionary* original=@{@"title":@"Native events",@"entry":@"scene.json",@"project":clipJSON([projectRoot stringByAppendingPathComponent:@"project.json"]),@"scene":clipJSON([projectRoot stringByAppendingPathComponent:@"scene.json"])};
  NSArray* objects=original[@"scene"][@"objects"];
  require(objects.count==1&&[objects[0][@"id"] isEqual:@1]&&[objects[0][@"animationlayers"][0][@"animation"] isEqual:@7]&&[objects[0][@"color"][@"script"] isKindOfClass:NSString.class],"Native event fixture must retain its explicit clip and actual color SceneScript");
  NSString* modelPath=@"models/editor/rig.mdl",*sourcePath=[projectRoot stringByAppendingPathComponent:modelPath];
  NSData* originalBytes=[NSData dataWithContentsOfFile:sourcePath],*expectedBytes=[NSData dataWithContentsOfFile:expectedPath];
  require(originalBytes!=nil&&expectedBytes!=nil,"Native event source or independently encoded expected MDL is missing");
  require(originalBytes.length>21&&std::memcmp(originalBytes.bytes,"MDLV0023",8)==0,"Native event source is not an actual MDLV0023 model");
  require(![originalBytes isEqualToData:expectedBytes],"Native event independent expected MDL must include the authored rename");
  NSString* originalHash=resourceHash(originalBytes);
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native event workbench creation failed");
  page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});
  NSWindow* window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1180,760) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;page.view.frame=window.contentView.bounds;[window.contentView addSubview:page.view];[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native event first frame timed out");require(!failure,"Native event workbench failed");
  require([page editorTestNativeViewIsAttached],"Native event CEF child is detached");command(page,@{@"type":@"thaw"});
  [page editorTestScript:@"(()=>{document.querySelector('#layers button[data-layer-id=\"1\"]').click();})();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"(()=>{document.getElementById('model-workspace').click();})();"];command(page,@{@"type":@"snapshot"});
  [page clipTestAwait:@"(()=>{const select=document.getElementById('model-event-select');return select&&select.options.length===3&&!select.disabled;})()"];
  [page editorTestScript:@"(()=>{document.getElementById('model-events-details').open=true;const select=document.getElementById('model-event-select');select.value='1';select.dispatchEvent(new Event('change',{bubbles:true}));})();"];
  [page clipTestAwait:@"document.getElementById('model-event-select').value==='1'&&document.getElementById('model-event-name').value==='fire'&&!document.getElementById('model-event-name').disabled"];
  fprintf(stderr,"Native events phase=trusted-focused-typing\n");
  [page editorTestScript:@"(()=>{const input=document.getElementById('model-event-name');input.scrollIntoView({block:'center'});input.focus();input.select();window.__eventTypedTrusted=false;input.addEventListener('input',event=>{window.__eventTypedTrusted=event.isTrusted;},{once:true});})();"];
  [page editorTestAwaitInput:@"#model-event-name" value:@"fire" focused:YES];[page editorTestType:@"Native fire"];
  [page editorTestAwaitInput:@"#model-event-name" value:@"Native fire" focused:YES];[page clipTestAwait:@"window.__eventTypedTrusted"];
  NSDictionary* frozen=command(page,@{@"type":@"freeze"}),*saved=frozen[@"document"];
  NSString* version=saved[@"resourceOverrides"][modelPath];
  require(version.length==64&&[frozen[@"dirty"] boolValue],"Native event focused input was not published before freeze");
  NSMutableDictionary* unchanged=[saved mutableCopy];[unchanged removeObjectForKey:@"resourceOverrides"];
  require([unchanged isEqual:original]&&[saved[@"resourceOverrides"] count]==1,"Native event resource edit changed scene, script, playback binding or unrelated resources");
  NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:version]];
  require(bytes!=nil&&[resourceHash(bytes) isEqual:version],"Native event MDL hash mismatch");
  require([bytes isEqualToData:expectedBytes],"Native event MDL differs from the independently encoded exact rename, including unknown JSON lexemes or unrelated sections");
  NSData* retained=[NSData dataWithContentsOfFile:sourcePath];require([retained isEqualToData:originalBytes]&&[resourceHash(retained) isEqual:originalHash],"Native event staging changed original project MDL bytes or hash");
  fprintf(stderr,"Native events phase=save-and-atomic-history\n");
  command(page,@{@"type":@"mark-saved",@"document":saved});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native event save acknowledgement remained dirty");
  command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native event undo did not restore the complete original document");
  command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native event redo lost its exact resource revision");
  fprintf(stderr,"Native events phase=scripts-skipped-edit-colors\n");
  [page clipTestAwait:@"(()=>{const playback=document.getElementById('playback');if(playback.getAttribute('aria-pressed')==='true')playback.click();return playback.getAttribute('aria-pressed')==='false';})()"];
  [page editorTestScript:@"(()=>{document.getElementById('timeline-toggle').click();})();"];[page clipTestAwait:@"!document.getElementById('timeline').hidden"];
  // Observe actual WebGL draws. Both meshes must stay green at callback
  // frames in edit mode, while Main export tests below require real red pixels.
  [page clipTestAwait:@"(()=>{const canvas=document.querySelector('#canvas canvas'),gl=canvas.getContext('webgl2');window.__eventPixels=null;window.__eventRestore=[];for(const name of ['drawElements','drawArrays']){const original=gl[name];window.__eventRestore.push(()=>gl[name]=original);gl[name]=function(...args){const result=original.apply(this,args),bytes=new Uint8Array(canvas.width*canvas.height*4),green=[0,0],red=[0,0],count=[0,0],xs=[0,0],ys=[0,0];gl.readPixels(0,0,canvas.width,canvas.height,gl.RGBA,gl.UNSIGNED_BYTE,bytes);for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){const at=(y*canvas.width+x)*4,half=x<canvas.width/2?0:1,isGreen=bytes[at]<70&&bytes[at+1]>180&&bytes[at+2]<70,isRed=bytes[at]>180&&bytes[at+1]<70&&bytes[at+2]<70;if(isGreen)green[half]++;if(isRed)red[half]++;if(isGreen||isRed){count[half]++;xs[half]+=x;ys[half]+=y;}}if(count.every(n=>n>100))window.__eventPixels={green,red,count,x:xs.map((v,i)=>v/count[i]),y:ys.map((v,i)=>v/count[i])};return result;};}return true;})()"];
  require(std::abs([command(page,@{@"type":@"seek",@"time":@0})[@"time"] doubleValue])<1e-8,"Native event seek did not acknowledge 0s");
  NSDictionary* initial=[page clipTestAwait:@"window.__eventPixels&&window.__eventPixels.green.every(n=>n>100)&&window.__eventPixels"][@"value"];
  require(std::abs([command(page,@{@"type":@"seek",@"time":@.5})[@"time"] doubleValue]-.5)<1e-8,"Native event seek did not acknowledge 0.5s");
  NSDictionary* middle=[page clipTestAwait:@"window.__eventPixels&&window.__eventPixels.green.every(n=>n>100)&&window.__eventPixels.red.every(n=>n<10)&&Math.abs(Number(document.getElementById('timeline-time').value)-.5)<1e-8&&window.__eventPixels"][@"value"];
  verifyEventStationary(initial,middle);[page clipTestAwait:@"!window.__animEventLog||window.__animEventLog.length===0"];
  require(std::abs([command(page,@{@"type":@"seek",@"time":@1.5})[@"time"] doubleValue]-1.5)<1e-8,"Native event seek did not acknowledge 1.5s");
  NSDictionary* green=[page clipTestAwait:@"window.__eventPixels&&window.__eventPixels.green.every(n=>n>100)&&Math.abs(Number(document.getElementById('timeline-time').value)-1.5)<1e-8&&window.__eventPixels"][@"value"];
  verifyEventStationary(initial,green);[page clipTestAwait:@"!window.__animEventLog||window.__animEventLog.length===0"];
  [page editorTestScript:@"(()=>{for(const restore of window.__eventRestore)restore();delete window.__eventRestore;delete window.__eventPixels;})();"];
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native event playback changed document content");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native event editor close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native event editor resources were not released");[window close];
  fprintf(stderr,"Native events: trusted focused input, exact independent MDL/hash/history, save and constant green edit pixels without callbacks passed\n");
}

static void verifyEventExport(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,BOOL package) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native event Main page creation failed");page.onError=^(NSError* value){failure=value;};[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Native event Main first frame timed out");require(!failure,"Native event Main rendering failed");
  __block BOOL greenSeen=NO,redSeen=NO;__block NSUInteger changes=0;__block NSInteger previous=-1;
  waitUntil(^{NSDictionary* pixels=eventPixels(page);if([pixels[@"count"][0] unsignedLongValue]<100||[pixels[@"count"][1] unsignedLongValue]<100)return NO;
    require(std::abs([pixels[@"x"][0] doubleValue]-284.5)<2&&std::abs([pixels[@"x"][1] doubleValue]-354.5)<2,"Native event Main changed horizontal bind placement");
    require(std::abs([pixels[@"y"][0] doubleValue]-179.5)<2&&std::abs([pixels[@"y"][1] doubleValue]-179.5)<2,"Native event Main moved a stationary mesh");
    const BOOL green=[pixels[@"green"][0] unsignedLongValue]>100&&[pixels[@"green"][1] unsignedLongValue]>100,red=[pixels[@"red"][0] unsignedLongValue]>100&&[pixels[@"red"][1] unsignedLongValue]>100;
    greenSeen|=green;redSeen|=red;if(green||red){const NSInteger current=red?1:0;if(previous>=0&&previous!=current)++changes;previous=current;}
    return BOOL(greenSeen&&redSeen&&changes>=2);
  },3.5,"Native event Main did not render both actual colors and two callback-driven color transitions");require(!failure,"Native event Main reported an error");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native event Main close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native event Main resources were not released");
  fprintf(stderr,"Main events %s: actual green/red callback pixels, %lu color transitions and both fixed meshes passed\n",package?"PKG":"loose",static_cast<unsigned long>(changes));
}
