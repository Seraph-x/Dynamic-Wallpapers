#pragma once

// Each fixture marker is 16x16 scene pixels. Keep independent channel counts so
// disappearance of one marker can never stand in for a solved chain.
static void ikInstallPixels(DWWebPage* page) {
  [page clipTestAwait:@"(()=>{const canvas=document.querySelector('#canvas canvas'),gl=canvas.getContext('webgl2');window.__ikPixels=null;window.__ikRestore=[];for(const name of ['drawElements','drawArrays']){const original=gl[name];window.__ikRestore.push(()=>gl[name]=original);gl[name]=function(...args){const result=original.apply(this,args),bytes=new Uint8Array(canvas.width*canvas.height*4),count=[0,0,0],xs=[0,0,0],ys=[0,0,0];gl.readPixels(0,0,canvas.width,canvas.height,gl.RGBA,gl.UNSIGNED_BYTE,bytes);for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){const at=(y*canvas.width+x)*4,r=bytes[at],g=bytes[at+1],b=bytes[at+2],marker=b>180&&r<70&&g<70?0:r>180&&g<70&&b<70?1:g>180&&r<70&&b<70?2:-1;if(marker>=0){count[marker]++;xs[marker]+=x;ys[marker]+=y;}}if(count.every(n=>n>20)){const scale=Math.min(canvas.width/640,canvas.height/360);window.__ikPixels={count,scale,x:xs.map((v,i)=>(v/count[i]+.5-canvas.width/2)/scale),y:ys.map((v,i)=>(v/count[i]+.5-canvas.height/2)/scale)};}return result;};}return true;})()"];
}
static void ikStopPixels(DWWebPage* page) {
  [page editorTestScript:@"(()=>{for(const restore of window.__ikRestore)restore();delete window.__ikRestore;delete window.__ikPixels;})();"];
}
static void ikAwaitPose(DWWebPage* page,BOOL solved) {
  NSString* expected=solved?@"[[-35,0],[-35,35],[0,35]]":@"[[-35,0],[0,0],[35,0]]";
  [page clipTestAwait:[NSString stringWithFormat:@"(()=>{const pixels=window.__ikPixels,expected=%@;return pixels&&pixels.scale>0&&pixels.count.every(n=>n>20)&&expected.every((point,i)=>Math.abs(pixels.x[i]-point[0])<1.5&&Math.abs(pixels.y[i]-point[1])<1.5)&&pixels;})()",expected]];
}
static void ikVerifySamples(DWWebPage* page) {
  ikInstallPixels(page);
  for(const double time:{0.,.5,1.}){
    require(std::abs([command(page,@{@"type":@"seek",@"time":@(time)})[@"time"] doubleValue]-time)<1e-8,"Native IK seek did not acknowledge its exact sample time");ikAwaitPose(page,YES);
  }
  ikStopPixels(page);
}

static void verifyIkWorkbench(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,NSString* resources,NSString* expectedPath) {
  NSDictionary* original=@{@"title":@"Native IK",@"entry":@"scene.json",@"project":clipJSON([projectRoot stringByAppendingPathComponent:@"project.json"]),@"scene":clipJSON([projectRoot stringByAppendingPathComponent:@"scene.json"])};
  NSArray* objects=original[@"scene"][@"objects"];
  require(objects.count==1&&[objects[0][@"id"] isEqual:@1]&&[objects[0][@"animationlayers"][0][@"animation"] isEqual:@7],"Native IK source must retain its explicit clip 7 playback binding");
  NSString* modelPath=@"models/editor/ik.mdl",*sourcePath=[projectRoot stringByAppendingPathComponent:modelPath];
  NSData* originalBytes=[NSData dataWithContentsOfFile:sourcePath],*expectedBytes=[NSData dataWithContentsOfFile:expectedPath];
  require(originalBytes!=nil&&expectedBytes!=nil,"Native IK source or independent expected MDL is missing");
  require(originalBytes.length>21&&std::memcmp(originalBytes.bytes,"MDLV0023",8)==0&&![originalBytes isEqualToData:expectedBytes],"Native IK fixture must contain an actual MDL and distinct independently authored solution");
  NSString* originalHash=resourceHash(originalBytes);
  NSError* error=nil;__block NSError* failure=nil;NSDictionary* saved=nil;
  @autoreleasepool {
    DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
    require(page!=nil,error.localizedDescription.UTF8String ?: "Native IK workbench creation failed");
    page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});NSWindow* window=fkHostWindow(page);
    [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native IK first frame timed out");require(!failure,"Native IK workbench failed");
    require([page editorTestNativeViewIsAttached],"Native IK CEF child is detached");command(page,@{@"type":@"thaw"});fkPauseWithTimeline(page);
    [page editorTestScript:@"(()=>{document.querySelector('#layers button[data-layer-id=\"1\"]').click();})();"];command(page,@{@"type":@"snapshot"});
    [page editorTestScript:@"(()=>{document.getElementById('model-workspace').click();})();"];command(page,@{@"type":@"snapshot"});
    [page clipTestAwait:@"(()=>{const bone=document.querySelector('#model-bones button[data-bone=\"2\"]');return bone&&!bone.disabled;})()"];
    [page editorTestScript:@"(()=>{document.querySelector('#model-bones button[data-bone=\"2\"]').click();const bones=document.getElementById('model-show-bones');if(bones.checked)bones.click();})();"];command(page,@{@"type":@"snapshot"});
    ikInstallPixels(page);command(page,@{@"type":@"seek",@"time":@0});ikAwaitPose(page,NO);
    [page editorTestScript:@"(()=>{document.getElementById('model-ik-open').click();})();"];
    [page clipTestAwait:@"document.getElementById('model-ik-dialog').open&&!document.getElementById('model-ik-cancel').disabled&&document.getElementById('model-ik-start').value==='0'&&document.getElementById('model-ik-end').value==='2'&&document.getElementById('model-ik-frame').value==='0'&&document.getElementById('model-ik-tx').value==='35'&&document.getElementById('model-ik-ty').value==='0'"];
    expectClipPending(page);fprintf(stderr,"Native IK phase=trusted-target-and-native-preview\n");
    [page editorTestScript:@"(()=>{for(const [id,value] of [['tx','0'],['tz','0'],['px','-35'],['py','35'],['pz','0']]){const input=document.getElementById('model-ik-'+id);input.value=value;input.dispatchEvent(new Event('input',{bubbles:true}));}const input=document.getElementById('model-ik-ty');input.scrollIntoView({block:'center'});input.focus();input.select();window.__ikTypedTrusted=false;input.addEventListener('input',event=>{window.__ikTypedTrusted=event.isTrusted;},{once:true});})();"];
    [page editorTestAwaitInput:@"#model-ik-ty" value:@"0" focused:YES];[page editorTestType:@"35"];
    [page editorTestAwaitInput:@"#model-ik-ty" value:@"35" focused:YES];[page clipTestAwait:@"window.__ikTypedTrusted"];
    [page editorTestScript:@"(()=>{document.getElementById('model-ik-preview').click();})();"];ikAwaitPose(page,YES);
    [page clipTestAwait:@"document.getElementById('model-ik-dialog').open&&!document.getElementById('model-ik-confirm').disabled"];
    NSArray* staged=[NSFileManager.defaultManager contentsOfDirectoryAtPath:resources error:&error];require(staged!=nil&&staged.count==0,"Native IK preview staged resource bytes before confirmation");
    require([[NSData dataWithContentsOfFile:sourcePath] isEqualToData:originalBytes],"Native IK preview changed the source MDL");ikStopPixels(page);
    fprintf(stderr,"Native IK phase=bake-and-exact-history\n");
    [page editorTestScript:@"(()=>{document.getElementById('model-ik-confirm').click();})();"];[page clipTestAwait:@"!document.getElementById('model-ik-dialog').open"];
    NSDictionary* frozen=command(page,@{@"type":@"freeze"});saved=frozen[@"document"];NSString* version=saved[@"resourceOverrides"][modelPath];
    require(version.length==64&&[frozen[@"dirty"] boolValue],"Native IK bake did not publish an authored MDL revision");
    NSMutableDictionary* unchanged=[saved mutableCopy];[unchanged removeObjectForKey:@"resourceOverrides"];
    require([unchanged isEqual:original]&&[saved[@"resourceOverrides"] count]==1,"Native IK bake changed scene playback or unrelated resources");
    NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:version]];
    require(bytes!=nil&&[resourceHash(bytes) isEqual:version]&&[bytes isEqualToData:expectedBytes],"Native IK bake does not match the independently encoded entire MDL and hash");
    command(page,@{@"type":@"mark-saved",@"document":saved});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native IK save acknowledgement remained dirty");
    command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native IK undo did not restore the complete original document");
    command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native IK redo lost its exact resource revision");
    [page clipTestAwait:@"document.getElementById('playback').getAttribute('aria-pressed')==='false'&&Math.abs(Number(document.getElementById('timeline-time').value))<1e-8"];
    ikVerifySamples(page);
    __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native IK editor close timed out");
    require(!failure&&page.closed&&runtime.activePageCount==0,"Native IK editor resources were not released");[window close];
  }
  @autoreleasepool {
    failure=nil;DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":saved} size:NSMakeSize(1180,760) error:&error];
    require(page!=nil,error.localizedDescription.UTF8String ?: "Native IK saved workspace reopen failed");page.onError=^(NSError* value){failure=value;};
    NSMutableDictionary* stats=configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});NSWindow* window=fkHostWindow(page);
    [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native IK reopened first frame timed out");require(!failure,"Native IK saved workspace rendering failed");
    require([stats[@"beforeReady"] unsignedIntegerValue]>0,"Native IK reopen did not read its saved resource revision before readiness");
    command(page,@{@"type":@"thaw"});fkPauseWithTimeline(page);ikVerifySamples(page);
    require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native IK saved workspace reopen changed authored content");
    __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native IK reopened editor close timed out");
    require(!failure&&page.closed&&runtime.activePageCount==0,"Native IK reopened resources were not released");[window close];
  }
  NSData* retained=[NSData dataWithContentsOfFile:sourcePath];require([retained isEqualToData:originalBytes]&&[resourceHash(retained) isEqual:originalHash],"Native IK staging or reopen changed original project MDL bytes or hash");
  fprintf(stderr,"Native IK: trusted target, all three native marker positions, independent exact MDL/hash, atomic history, save/reopen and release passed\n");
}

// OSR native image bytes are BGRA, independently of the Editor's GL RGBA hook.
static NSDictionary* ikMainPixels(DWWebPage* page) {
  CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;if(!image)return @{@"count":@[@0,@0,@0]};
  NSData* data=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));require(data!=nil,"Native IK Main pixel read failed");
  const auto* bytes=static_cast<const UInt8*>(data.bytes);
  const size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),rowBytes=CGImageGetBytesPerRow(image);size_t count[3]={0,0,0};double xs[3]={0,0,0},ys[3]={0,0,0};
  for(size_t y=0;y<height;++y)for(size_t x=0;x<width;++x){const size_t at=y*rowBytes+x*4;const UInt8 b=bytes[at],g=bytes[at+1],r=bytes[at+2];
    const int marker=b>180&&r<70&&g<70?0:r>180&&g<70&&b<70?1:g>180&&r<70&&b<70?2:-1;
    if(marker>=0){++count[marker];xs[marker]+=x;ys[marker]+=y;}
  }
  return @{@"count":@[@(count[0]),@(count[1]),@(count[2])],@"x":@[@(count[0]?xs[0]/count[0]:0),@(count[1]?xs[1]/count[1]:0),@(count[2]?xs[2]/count[2]:0)],
    @"y":@[@(count[0]?ys[0]/count[0]:0),@(count[1]?ys[1]/count[1]:0),@(count[2]?ys[2]/count[2]:0)]};
}
static void verifyIkExport(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,BOOL package) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native IK Main page creation failed");page.onError=^(NSError* value){failure=value;};[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Native IK Main first frame timed out");require(!failure,"Native IK Main rendering failed");
  __block double started=-1;__block NSUInteger samples=0;
  waitUntil(^{NSDictionary* pixels=ikMainPixels(page);for(NSNumber* count in pixels[@"count"])if(count.unsignedLongValue<=20)return NO;
    const double expected[3][2]={{284.5,179.5},{284.5,144.5},{319.5,144.5}};
    for(NSUInteger marker=0;marker<3;++marker)require(std::abs([pixels[@"x"][marker] doubleValue]-expected[marker][0])<1.5&&std::abs([pixels[@"y"][marker] doubleValue]-expected[marker][1])<1.5,"Native IK Main did not render all blue/root, red/middle and green/tip markers at their solved positions");
    const double now=NSProcessInfo.processInfo.systemUptime;if(started<0)started=now;++samples;return BOOL(samples>1&&now-started>=.5);
  },3,"Native IK Main did not retain all three actual solved marker pixels across later frames");require(!failure,"Native IK Main reported an error");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native IK Main close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native IK Main resources were not released");
  fprintf(stderr,"Main IK %s: actual blue/root, red/middle and green/tip solved centroids held for >=0.5s (%lu samples) passed\n",package?"PKG":"loose",static_cast<unsigned long>(samples));
}
