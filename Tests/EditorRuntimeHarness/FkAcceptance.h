#pragma once

static void fkInstallPixels(DWWebPage* page) {
  [page clipTestAwait:@"(()=>{const canvas=document.querySelector('#canvas canvas'),gl=canvas.getContext('webgl2');window.__fkPixels=null;window.__fkRestore=[];for(const name of ['drawElements','drawArrays']){const original=gl[name];window.__fkRestore.push(()=>gl[name]=original);gl[name]=function(...args){const result=original.apply(this,args),bytes=new Uint8Array(canvas.width*canvas.height*4),count=[0,0],xs=[0,0],ys=[0,0];gl.readPixels(0,0,canvas.width,canvas.height,gl.RGBA,gl.UNSIGNED_BYTE,bytes);for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){const at=(y*canvas.width+x)*4;if(bytes[at]<70&&bytes[at+1]>180&&bytes[at+2]<70){const half=x<canvas.width/2?0:1;count[half]++;xs[half]+=x;ys[half]+=y;}}if(count.every(n=>n>100)){const scale=(xs[1]/count[1]-xs[0]/count[0])/70;window.__fkPixels={parent:(ys[0]/count[0]-(canvas.height-1)/2)/scale,right:(ys[1]/count[1]-ys[0]/count[0])/scale,scale};}return result;};}return true;})()"];
}
static void fkStopPixels(DWWebPage* page) {
  [page editorTestScript:@"(()=>{for(const restore of window.__fkRestore)restore();delete window.__fkRestore;delete window.__fkPixels;})();"];
}
static void fkAwaitPose(DWWebPage* page,double parent,double right) {
  [page clipTestAwait:[NSString stringWithFormat:@"window.__fkPixels&&window.__fkPixels.scale>0&&Math.abs(window.__fkPixels.parent-%.9g)<1.5&&Math.abs(window.__fkPixels.right-%.9g)<1.5&&window.__fkPixels",parent,right]];
}
static void fkVerifySamples(DWWebPage* page,double parent) {
  fkInstallPixels(page);
  for(const double time:{0.,.25,.5,1.}){
    require(std::abs([command(page,@{@"type":@"seek",@"time":@(time)})[@"time"] doubleValue]-time)<1e-8,"Native FK sample seek did not acknowledge its exact time");
    fkAwaitPose(page,parent,time*60);
  }
  fkStopPixels(page);
}
static NSWindow* fkHostWindow(DWWebPage* page) {
  NSWindow* window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1180,760) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;page.view.frame=window.contentView.bounds;[window.contentView addSubview:page.view];[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];return window;
}
static void fkPauseWithTimeline(DWWebPage* page) {
  [page clipTestAwait:@"(()=>{const playback=document.getElementById('playback');if(playback.getAttribute('aria-pressed')==='true')playback.click();return playback.getAttribute('aria-pressed')==='false';})()"];
  [page editorTestScript:@"(()=>{document.getElementById('timeline-toggle').click();})();"];[page clipTestAwait:@"!document.getElementById('timeline').hidden"];
}

static void verifyFkWorkbench(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,NSString* resources,NSString* expectedPath) {
  NSDictionary* original=@{@"title":@"Native FK",@"entry":@"scene.json",@"project":clipJSON([projectRoot stringByAppendingPathComponent:@"project.json"]),@"scene":clipJSON([projectRoot stringByAppendingPathComponent:@"scene.json"])};
  NSArray* objects=original[@"scene"][@"objects"];
  require(objects.count==1&&[objects[0][@"id"] isEqual:@1]&&[objects[0][@"animationlayers"][0][@"animation"] isEqual:@7],"Native FK export must retain its explicit clip 7 playback binding");
  NSString* modelPath=@"models/editor/rig.mdl",*sourcePath=[projectRoot stringByAppendingPathComponent:modelPath];
  NSData* originalBytes=[NSData dataWithContentsOfFile:sourcePath],*expectedBytes=[NSData dataWithContentsOfFile:expectedPath];
  require(originalBytes!=nil&&expectedBytes!=nil,"Native FK source or independent expected MDL is missing");
  require(originalBytes.length>21&&std::memcmp(originalBytes.bytes,"MDLV0023",8)==0&&![originalBytes isEqualToData:expectedBytes],"Native FK fixture must contain an actual MDL and distinct independently authored parent delta");
  NSString* originalHash=resourceHash(originalBytes);
  NSError* error=nil;__block NSError* failure=nil;NSDictionary* saved=nil;
  @autoreleasepool {
    DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
    require(page!=nil,error.localizedDescription.UTF8String ?: "Native FK workbench creation failed");
    page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});NSWindow* window=fkHostWindow(page);
    [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native FK first frame timed out");require(!failure,"Native FK workbench failed");
    require([page editorTestNativeViewIsAttached],"Native FK CEF child is detached");command(page,@{@"type":@"thaw"});fkPauseWithTimeline(page);
    [page editorTestScript:@"(()=>{document.querySelector('#layers button[data-layer-id=\"1\"]').click();})();"];command(page,@{@"type":@"snapshot"});
    [page editorTestScript:@"(()=>{document.getElementById('model-workspace').click();})();"];command(page,@{@"type":@"snapshot"});
    [page clipTestAwait:@"(()=>{const bone=document.querySelector('#model-bones button[data-bone=\"0\"]');return bone&&!bone.disabled;})()"];
    [page editorTestScript:@"(()=>{document.querySelector('#model-bones button[data-bone=\"0\"]').click();const bones=document.getElementById('model-show-bones');if(bones.checked)bones.click();})();"];command(page,@{@"type":@"snapshot"});
    fkInstallPixels(page);command(page,@{@"type":@"seek",@"time":@0});fkAwaitPose(page,20,0);
    [page editorTestScript:@"(()=>{document.getElementById('model-fk-open').click();})();"];
    [page clipTestAwait:@"document.getElementById('model-fk-dialog').open&&!document.getElementById('model-fk-cancel').disabled&&document.getElementById('model-fk-start').value==='0'&&document.getElementById('model-fk-end').value==='2'&&document.getElementById('model-fk-frame').value==='0'"];
    expectClipPending(page);fprintf(stderr,"Native FK phase=trusted-focused-preview\n");
    [page editorTestScript:@"(()=>{const input=document.getElementById('model-fk-ty');input.scrollIntoView({block:'center'});input.focus();input.select();window.__fkTypedTrusted=false;input.addEventListener('input',event=>{window.__fkTypedTrusted=event.isTrusted;},{once:true});})();"];
    [page editorTestAwaitInput:@"#model-fk-ty" value:@"0" focused:YES];[page editorTestType:@"10"];
    [page editorTestAwaitInput:@"#model-fk-ty" value:@"10" focused:YES];[page clipTestAwait:@"window.__fkTypedTrusted"];
    [page editorTestScript:@"(()=>{document.getElementById('model-fk-preview').click();})();"];fkAwaitPose(page,30,0);
    [page clipTestAwait:@"document.getElementById('model-fk-dialog').open&&!document.getElementById('model-fk-confirm').disabled"];
    NSArray* staged=[NSFileManager.defaultManager contentsOfDirectoryAtPath:resources error:&error];require(staged!=nil&&staged.count==0,"Native FK preview staged resource bytes before confirmation");
    require([[NSData dataWithContentsOfFile:sourcePath] isEqualToData:originalBytes],"Native FK preview changed the source MDL");fkStopPixels(page);
    fprintf(stderr,"Native FK phase=bake-and-exact-history\n");
    [page editorTestScript:@"(()=>{document.getElementById('model-fk-confirm').click();})();"];[page clipTestAwait:@"!document.getElementById('model-fk-dialog').open"];
    NSDictionary* frozen=command(page,@{@"type":@"freeze"});saved=frozen[@"document"];NSString* version=saved[@"resourceOverrides"][modelPath];
    require(version.length==64&&[frozen[@"dirty"] boolValue],"Native FK bake did not publish an authored MDL revision");
    NSMutableDictionary* unchanged=[saved mutableCopy];[unchanged removeObjectForKey:@"resourceOverrides"];
    require([unchanged isEqual:original]&&[saved[@"resourceOverrides"] count]==1,"Native FK bake changed scene playback or unrelated resources");
    NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:version]];
    require(bytes!=nil&&[resourceHash(bytes) isEqual:version]&&[bytes isEqualToData:expectedBytes],"Native FK bake does not match the independently encoded entire MDL and hash");
    command(page,@{@"type":@"mark-saved",@"document":saved});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native FK save acknowledgement remained dirty");
    command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native FK undo did not restore the complete original document");
    command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native FK redo lost its exact resource revision");
    [page clipTestAwait:@"document.getElementById('playback').getAttribute('aria-pressed')==='false'&&Math.abs(Number(document.getElementById('timeline-time').value))<1e-8"];
    fkVerifySamples(page,30);
    __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native FK editor close timed out");
    require(!failure&&page.closed&&runtime.activePageCount==0,"Native FK editor resources were not released");[window close];
  }
  @autoreleasepool {
    failure=nil;DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":saved} size:NSMakeSize(1180,760) error:&error];
    require(page!=nil,error.localizedDescription.UTF8String ?: "Native FK saved workspace reopen failed");page.onError=^(NSError* value){failure=value;};
    NSMutableDictionary* stats=configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});NSWindow* window=fkHostWindow(page);
    [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native FK reopened first frame timed out");require(!failure,"Native FK saved workspace rendering failed");
    require([stats[@"beforeReady"] unsignedIntegerValue]>0,"Native FK reopen did not read its saved resource revision before readiness");
    command(page,@{@"type":@"thaw"});fkPauseWithTimeline(page);fkVerifySamples(page,30);
    require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native FK saved workspace reopen changed authored content");
    __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native FK reopened editor close timed out");
    require(!failure&&page.closed&&runtime.activePageCount==0,"Native FK reopened resources were not released");[window close];
  }
  NSData* retained=[NSData dataWithContentsOfFile:sourcePath];require([retained isEqualToData:originalBytes]&&[resourceHash(retained) isEqual:originalHash],"Native FK staging or reopen changed original project MDL bytes or hash");
  fprintf(stderr,"Native FK: trusted focused preview, parent/descendant pixels, independent exact MDL/hash, atomic history, save/reopen and four known samples passed\n");
}

static void verifyFkExport(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,BOOL package) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native FK Main page creation failed");page.onError=^(NSError* value){failure=value;};[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Native FK Main first frame timed out");require(!failure,"Native FK Main rendering failed");
  __block BOOL zero=NO,quarter=NO,half=NO,peak=NO;__block double low=1e9,high=-1e9;
  waitUntil(^{NSArray* pixels=modelPixels(page);if([pixels[0] unsignedLongValue]<100||[pixels[1] unsignedLongValue]<100)return NO;
    require(std::abs([pixels[2] doubleValue]-284.5)<2&&std::abs([pixels[3] doubleValue]-354.5)<2,"Native FK Main changed descendant horizontal bind placement");
    require(std::abs([pixels[4] doubleValue]-159.5)<2,"Native FK Main did not move the stationary descendant upward by the authored parent 20px");
    const double delta=[pixels[4] doubleValue]-[pixels[5] doubleValue];require(delta>=-2&&delta<=62,"Native FK Main right descendant left the authored extra 0..60px range");
    low=std::min(low,delta);high=std::max(high,delta);zero|=std::abs(delta)<2;quarter|=std::abs(delta-15)<2;half|=std::abs(delta-30)<2;peak|=std::abs(delta-60)<2;
    return BOOL(zero&&quarter&&half&&peak&&high-low>40);
  },3,"Native FK Main did not render all known 0/15/30/60px descendant motion levels over its parent 20px delta");require(!failure,"Native FK Main reported an error");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native FK Main close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native FK Main resources were not released");
  fprintf(stderr,"Main FK %s: fixed horizontal placement, authored parent 20px and known 0/15/30/60px right descendant motion %.2f..%.2f px passed\n",package?"PKG":"loose",low,high);
}
