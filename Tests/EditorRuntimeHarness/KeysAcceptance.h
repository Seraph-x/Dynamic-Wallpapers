#pragma once

static void keysVerifyMetadata(NSData* bytes) {
  NSData* metadata=[@"{\"future\":\"right\",\"dynamicWallpaperBoneKeys\":{\"version\":1,\"clips\":{\"7\":{\"frameCount\":4,\"keys\":[0,4]}}}}" dataUsingEncoding:NSUTF8StringEncoding];
  require([bytes rangeOfData:metadata options:0 range:NSMakeRange(0,bytes.length)].location!=NSNotFound,"Native sparse keys did not retain the exact two-key Right metadata and unrelated future field");
}
static void keysOpenModel(DWWebPage* page) {
  [page editorTestScript:@"(()=>{document.querySelector('#layers button[data-layer-id=\"1\"]').click();})();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"(()=>{document.getElementById('model-workspace').click();})();"];command(page,@{@"type":@"snapshot"});
  [page clipTestAwait:@"(()=>{const bone=document.querySelector('#model-bones button[data-bone=\"2\"]');return bone&&!bone.disabled;})()"];
  [page editorTestScript:@"(()=>{document.querySelector('#model-bones button[data-bone=\"2\"]').click();const bones=document.getElementById('model-show-bones');if(bones.checked)bones.click();document.getElementById('model-keys-details').open=true;})();"];command(page,@{@"type":@"snapshot"});
}
static void keysSelectEndpoint(DWWebPage* page,NSString* value) {
  [page editorTestScript:@"(()=>{const input=document.getElementById('model-keys-frame');input.value='4';input.dispatchEvent(new Event('change',{bubbles:true}));})();"];
  [page editorTestAwaitInput:@"#model-key-ty" value:value];
  [page clipTestAwait:@"document.getElementById('model-keys-frame').value==='4'&&!document.getElementById('model-key-ty').disabled"];
}
static void keysVerifySamples(DWWebPage* page) {
  fkInstallPixels(page);
  for(const double time:{0.,.25,.5,1.}){
    require(std::abs([command(page,@{@"type":@"seek",@"time":@(time)})[@"time"] doubleValue]-time)<1e-8,"Native sparse-key seek did not acknowledge its exact sample time");fkAwaitPose(page,0,time*120);
  }
  fkStopPixels(page);
}

static void verifyKeysWorkbench(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,NSString* resources,NSString* expectedPath) {
  NSDictionary* original=@{@"title":@"Native bone keys",@"entry":@"scene.json",@"project":clipJSON([projectRoot stringByAppendingPathComponent:@"project.json"]),@"scene":clipJSON([projectRoot stringByAppendingPathComponent:@"scene.json"])};
  NSArray* objects=original[@"scene"][@"objects"];
  require(objects.count==1&&[objects[0][@"id"] isEqual:@1]&&[objects[0][@"animationlayers"][0][@"animation"] isEqual:@7],"Native sparse-key source must retain its explicit clip 7 playback binding");
  NSString* modelPath=@"models/editor/rig.mdl",*sourcePath=[projectRoot stringByAppendingPathComponent:modelPath];
  NSData* originalBytes=[NSData dataWithContentsOfFile:sourcePath],*expectedBytes=[NSData dataWithContentsOfFile:expectedPath];
  require(originalBytes!=nil&&expectedBytes!=nil,"Native sparse-key source or independent expected MDL is missing");
  require(originalBytes.length>21&&std::memcmp(originalBytes.bytes,"MDLV0023",8)==0&&![originalBytes isEqualToData:expectedBytes],"Native sparse-key fixture must contain an actual MDL and distinct independently authored endpoint");keysVerifyMetadata(expectedBytes);
  NSString* originalHash=resourceHash(originalBytes);
  NSError* error=nil;__block NSError* failure=nil;NSDictionary* saved=nil;
  @autoreleasepool {
    DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
    require(page!=nil,error.localizedDescription.UTF8String ?: "Native sparse-key workbench creation failed");
    page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});NSWindow* window=fkHostWindow(page);
    [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native sparse-key first frame timed out");require(!failure,"Native sparse-key workbench failed");
    require([page editorTestNativeViewIsAttached],"Native sparse-key CEF child is detached");command(page,@{@"type":@"thaw"});fkPauseWithTimeline(page);keysOpenModel(page);
    [page clipTestAwait:@"document.getElementById('model-keys-frame').value==='0'&&!document.getElementById('model-key-adopt').disabled"];
    fprintf(stderr,"Native keys phase=confirmed-adoption-and-lossless-reduction\n");
    [page editorTestScript:@"(()=>{document.getElementById('model-key-adopt').click();})();"];
    [page clipTestAwait:@"document.getElementById('model-key-dialog').open&&!document.getElementById('model-key-confirm').disabled"];expectClipPending(page);
    [page editorTestScript:@"(()=>{document.getElementById('model-key-confirm').click();})();"];[page clipTestAwait:@"!document.getElementById('model-key-dialog').open"];
    NSDictionary* adopted=command(page,@{@"type":@"snapshot"})[@"document"];
    require(![adopted isEqual:original]&&[adopted[@"resourceOverrides"] count]==1,"Native sparse-key adoption did not create its own metadata revision");
    [page clipTestAwait:@"!document.getElementById('model-key-reduce').disabled"];
    [page editorTestScript:@"(()=>{document.getElementById('model-key-reduce').click();})();"];
    NSDictionary* beforeEdit=command(page,@{@"type":@"snapshot"})[@"document"];NSString* reducedVersion=beforeEdit[@"resourceOverrides"][modelPath];
    require(reducedVersion.length==64&&![beforeEdit isEqual:adopted],"Native lossless reduction did not preserve a separate two-anchor revision");
    NSData* reduced=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:reducedVersion]];
    require(reduced!=nil&&[resourceHash(reduced) isEqual:reducedVersion],"Native reduced-key MDL hash mismatch");keysVerifyMetadata(reduced);
    [page clipTestAwait:@"document.getElementById('model-key-count').textContent.trim()==='2'"];
    keysSelectEndpoint(page,@"60");fprintf(stderr,"Native keys phase=trusted-focused-endpoint\n");
    [page editorTestScript:@"(()=>{const input=document.getElementById('model-key-ty');input.scrollIntoView({block:'center'});input.focus();input.select();window.__keysTypedTrusted=false;input.addEventListener('input',event=>{window.__keysTypedTrusted=event.isTrusted;},{once:true});})();"];
    [page editorTestAwaitInput:@"#model-key-ty" value:@"60" focused:YES];[page editorTestType:@"120"];
    [page editorTestAwaitInput:@"#model-key-ty" value:@"120" focused:YES];[page clipTestAwait:@"window.__keysTypedTrusted"];
    NSDictionary* frozen=command(page,@{@"type":@"freeze"});saved=frozen[@"document"];NSString* version=saved[@"resourceOverrides"][modelPath];
    require(version.length==64&&[frozen[@"dirty"] boolValue],"Native sparse-key unblurred endpoint was not published before freeze");
    NSMutableDictionary* unchanged=[saved mutableCopy];[unchanged removeObjectForKey:@"resourceOverrides"];
    require([unchanged isEqual:original]&&[saved[@"resourceOverrides"] count]==1,"Native sparse-key edit changed scene playback or unrelated resources");
    NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:version]];
    require(bytes!=nil&&[resourceHash(bytes) isEqual:version]&&[bytes isEqualToData:expectedBytes],"Native sparse-key edit does not match the independently encoded whole MDL, metadata and hash");keysVerifyMetadata(bytes);
    fprintf(stderr,"Native keys phase=save-and-exact-endpoint-history\n");
    command(page,@{@"type":@"mark-saved",@"document":saved});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native sparse-key save acknowledgement remained dirty");
    command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:beforeEdit],"Native endpoint undo did not restore the complete adopted and reduced pre-edit revision");
    command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native endpoint redo lost its exact authored resource revision");
    keysSelectEndpoint(page,@"120");fkInstallPixels(page);
    [page editorTestScript:@"(()=>{document.getElementById('model-key-preview').click();})();"];fkAwaitPose(page,0,120);
    [page clipTestAwait:@"Math.abs(Number(document.getElementById('timeline-time').value)-1)<1e-8"];fkStopPixels(page);keysVerifySamples(page);
    require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native sparse-key selection or preview changed authored content");
    __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native sparse-key editor close timed out");
    require(!failure&&page.closed&&runtime.activePageCount==0,"Native sparse-key editor resources were not released");[window close];
  }
  @autoreleasepool {
    failure=nil;DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":saved} size:NSMakeSize(1180,760) error:&error];
    require(page!=nil,error.localizedDescription.UTF8String ?: "Native saved sparse-key workspace reopen failed");page.onError=^(NSError* value){failure=value;};
    NSMutableDictionary* stats=configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});NSWindow* window=fkHostWindow(page);
    [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native reopened sparse-key first frame timed out");require(!failure,"Native saved sparse-key rendering failed");
    require([stats[@"beforeReady"] unsignedIntegerValue]>0,"Native sparse-key reopen did not read its saved MDL revision before readiness");
    command(page,@{@"type":@"thaw"});fkPauseWithTimeline(page);keysOpenModel(page);keysSelectEndpoint(page,@"120");
    [page clipTestAwait:@"document.getElementById('model-key-count').textContent.trim()==='2'"];
    NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:saved[@"resourceOverrides"][modelPath]]];
    require([bytes isEqualToData:expectedBytes],"Native saved sparse-key resource changed during real reopen");keysVerifyMetadata(bytes);keysVerifySamples(page);
    require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native sparse-key reopen changed authored content");
    __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native reopened sparse-key close timed out");
    require(!failure&&page.closed&&runtime.activePageCount==0,"Native reopened sparse-key resources were not released");[window close];
  }
  NSData* retained=[NSData dataWithContentsOfFile:sourcePath];require([retained isEqualToData:originalBytes]&&[resourceHash(retained) isEqual:originalHash],"Native sparse-key staging or reopen changed original MDL bytes or hash");
  fprintf(stderr,"Native keys: confirmed adoption/reduction, trusted focused endpoint, independent exact MDL/map/hash, pre-edit history, real saved reopen and actual samples passed\n");
}

static void verifyKeysExport(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,BOOL package) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native sparse-key Main page creation failed");page.onError=^(NSError* value){failure=value;};[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Native sparse-key Main first frame timed out");require(!failure,"Native sparse-key Main rendering failed");
  __block BOOL zero=NO,quarter=NO,half=NO,peak=NO;__block double low=1e9,high=-1e9;
  waitUntil(^{NSArray* pixels=modelPixels(page);if([pixels[0] unsignedLongValue]<100||[pixels[1] unsignedLongValue]<100)return NO;
    require(std::abs([pixels[2] doubleValue]-284.5)<2&&std::abs([pixels[3] doubleValue]-354.5)<2,"Native sparse-key Main changed horizontal bind placement");
    require(std::abs([pixels[4] doubleValue]-179.5)<2,"Native sparse-key Main moved the stationary left mesh");
    const double delta=[pixels[4] doubleValue]-[pixels[5] doubleValue];require(delta>=-2&&delta<=122,"Native sparse-key Main right mesh left the authored 0..120px range");
    low=std::min(low,delta);high=std::max(high,delta);zero|=std::abs(delta)<3;quarter|=std::abs(delta-30)<3;half|=std::abs(delta-60)<3;peak|=std::abs(delta-120)<3;
    return BOOL(zero&&quarter&&half&&peak&&high-low>100);
  },3,"Native sparse-key Main did not render all known 0/30/60/120px motion levels");require(!failure,"Native sparse-key Main reported an error");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native sparse-key Main close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native sparse-key Main resources were not released");
  fprintf(stderr,"Main keys %s: static left bind, exact horizontal placement and known 0/30/60/120px motion %.2f..%.2f px passed\n",package?"PKG":"loose",low,high);
}
