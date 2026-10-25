#pragma once

// The fixture owns one mirror clip (7), three bones and three dense samples.
// Match the unique complete right-bone sample before changing its Y component;
// the exact-byte comparison also protects every other sample and MDL section.
static void verifyPoseMDL(NSData* bytes,NSData* original) {
  require(original.length>21&&std::memcmp(original.bytes,"MDLV0023",8)==0,"Native pose source is not an actual MDLV0023 model");
  require(clipU32(original,clipSection(original,@"MDLA0006")+13)==1,"Native pose fixture must contain only its authored clip");
  const float sample[]={35,120,0,0,0,0,1,1,1};
  uint32_t encoded[9];
  for(NSUInteger index=0;index<9;++index){uint32_t bits=0;std::memcpy(&bits,&sample[index],sizeof(bits));encoded[index]=CFSwapInt32HostToLittle(bits);}
  NSData* signature=[NSData dataWithBytes:encoded length:sizeof(encoded)];
  const NSRange found=[original rangeOfData:signature options:0 range:NSMakeRange(0,original.length)];
  require(found.location!=NSNotFound,"Native pose source is missing its exact 120px right-bone sample");
  const NSUInteger following=NSMaxRange(found);
  require([original rangeOfData:signature options:0 range:NSMakeRange(following,original.length-following)].location==NSNotFound,"Native pose source sample signature is not unique");
  NSMutableData* expected=[original mutableCopy];float value=140;uint32_t bits=0;std::memcpy(&bits,&value,sizeof(bits));bits=CFSwapInt32HostToLittle(bits);
  [expected replaceBytesInRange:NSMakeRange(found.location+sizeof(float),sizeof(float)) withBytes:&bits];
  require([bytes isEqualToData:expected],"Native pose edit did not change precisely the selected frame's Y Float32 and preserve every unrelated MDL byte");
}

static void verifyPoseWorkbench(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,NSString* resources) {
  NSDictionary* original=@{@"title":@"Native poses",@"entry":@"scene.json",@"project":clipJSON([projectRoot stringByAppendingPathComponent:@"project.json"]),@"scene":clipJSON([projectRoot stringByAppendingPathComponent:@"scene.json"])};
  NSArray* objects=original[@"scene"][@"objects"];
  require(objects.count==1&&[objects[0][@"id"] isEqual:@1]&&[objects[0][@"animationlayers"][0][@"animation"] isEqual:@7],"Native pose export must explicitly assign clip 7 to the puppet");
  NSString* modelPath=@"models/editor/rig.mdl";NSData* originalBytes=[NSData dataWithContentsOfFile:[projectRoot stringByAppendingPathComponent:modelPath]];
  require(originalBytes!=nil,"Native pose exported MDL is missing");
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native pose workbench creation failed");
  page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});
  NSWindow* window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1180,760) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;page.view.frame=window.contentView.bounds;[window.contentView addSubview:page.view];[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native pose first frame timed out");require(!failure,"Native pose workbench failed");
  require([page editorTestNativeViewIsAttached],"Native pose CEF child is detached");command(page,@{@"type":@"thaw"});
  [page editorTestScript:@"(()=>{document.querySelector('#layers button[data-layer-id=\"1\"]').click();})();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"(()=>{document.getElementById('model-workspace').click();})();"];command(page,@{@"type":@"snapshot"});
  [page clipTestAwait:@"(()=>{const bone=document.querySelector('#model-bones button[data-bone=\"2\"]');return bone&&!bone.disabled;})()"];
  [page editorTestScript:@"(()=>{document.querySelector('#model-bones button[data-bone=\"2\"]').click();})();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"(()=>{document.getElementById('model-poses-details').open=true;const input=document.getElementById('model-pose-frame');input.value='1';input.dispatchEvent(new Event('change',{bubbles:true}));})();"];
  [page clipTestAwait:@"document.getElementById('model-pose-frame').value==='1'&&document.getElementById('model-pose-ty').value==='120'&&!document.getElementById('model-pose-ty').disabled"];
  fprintf(stderr,"Native poses phase=trusted-focused-typing\n");
  [page editorTestScript:@"(()=>{const input=document.getElementById('model-pose-ty');input.scrollIntoView({block:'center'});input.focus();input.select();window.__poseTypedTrusted=false;input.addEventListener('input',event=>{window.__poseTypedTrusted=event.isTrusted;},{once:true});})();"];
  [page editorTestAwaitInput:@"#model-pose-ty" value:@"120" focused:YES];[page editorTestType:@"140"];
  [page editorTestAwaitInput:@"#model-pose-ty" value:@"140" focused:YES];[page clipTestAwait:@"window.__poseTypedTrusted"];
  NSDictionary* frozen=command(page,@{@"type":@"freeze"}),*saved=frozen[@"document"];
  NSString* version=saved[@"resourceOverrides"][modelPath];
  require(version.length==64&&[frozen[@"dirty"] boolValue],"Native pose focused input was not published before freeze");
  NSMutableDictionary* unchanged=[saved mutableCopy];[unchanged removeObjectForKey:@"resourceOverrides"];
  require([unchanged isEqual:original]&&[saved[@"resourceOverrides"] count]==1,"Native pose resource edit changed scene, playback assignment or unrelated resources");
  NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:version]];
  require(bytes!=nil&&[resourceHash(bytes) isEqual:version],"Native pose MDL hash mismatch");verifyPoseMDL(bytes,originalBytes);
  fprintf(stderr,"Native poses phase=save-and-atomic-history\n");
  command(page,@{@"type":@"mark-saved",@"document":saved});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native pose save acknowledgement remained dirty");
  command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native pose undo did not restore the entire original document");
  command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native pose redo lost its exact resource revision");
  fprintf(stderr,"Native poses phase=exact-frame-preview\n");
  [page clipTestAwait:@"(()=>{const playback=document.getElementById('playback');if(playback.getAttribute('aria-pressed')==='true')playback.click();return playback.getAttribute('aria-pressed')==='false';})()"];
  // Timeline refreshes its time input only while its panel is visible.
  [page editorTestScript:@"(()=>{document.getElementById('timeline-toggle').click();})();"];
  [page clipTestAwait:@"!document.getElementById('timeline').hidden"];
  [page clipTestAwait:@"(()=>{const canvas=document.querySelector('#canvas canvas'),gl=canvas.getContext('webgl2');window.__posePixels=null;window.__poseRestore=[];for(const name of ['drawElements','drawArrays']){const original=gl[name];window.__poseRestore.push(()=>gl[name]=original);gl[name]=function(...args){const result=original.apply(this,args),bytes=new Uint8Array(canvas.width*canvas.height*4),counts=[0,0],xs=[0,0],ys=[0,0];gl.readPixels(0,0,canvas.width,canvas.height,gl.RGBA,gl.UNSIGNED_BYTE,bytes);for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){const at=(y*canvas.width+x)*4;if(bytes[at]<70&&bytes[at+1]>180&&bytes[at+2]<70){const half=x<canvas.width/2?0:1;counts[half]++;xs[half]+=x;ys[half]+=y;}}if(counts.every(n=>n>100)){const scale=(xs[1]/counts[1]-xs[0]/counts[0])/70;window.__posePixels={displacement:(ys[1]/counts[1]-ys[0]/counts[0])/scale,scale};}return result;};}return true;})()"];
  [page editorTestScript:@"(()=>{document.getElementById('model-pose-preview').click();})();"];
  NSDictionary* pose=[page clipTestAwait:@"window.__posePixels&&window.__posePixels.scale>0&&Math.abs(window.__posePixels.displacement-140)<1.5&&Math.abs(Number(document.getElementById('timeline-time').value)-.5)<1e-8&&window.__posePixels"][@"value"];
  require(std::abs([pose[@"displacement"] doubleValue]-140)<1.5,"Native pose frame preview did not render the actual 140px displacement at 0.5s");
  [page editorTestScript:@"(()=>{for(const restore of window.__poseRestore)restore();delete window.__poseRestore;delete window.__posePixels;})();"];
  require([[NSData dataWithContentsOfFile:[projectRoot stringByAppendingPathComponent:modelPath]] isEqualToData:originalBytes],"Native pose staging rewrote the source project's MDL");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native pose editor close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native pose editor resources were not released");[window close];
  fprintf(stderr,"Native poses: trusted focused input, exact Float32/MDL/hash, save, atomic history and actual frame preview passed\n");
}

static void verifyPoseExport(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,BOOL package) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native pose Main page creation failed");page.onError=^(NSError* value){failure=value;};[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Native pose Main first frame timed out");require(!failure,"Native pose Main rendering failed");
  __block double low=1e9,high=-1e9;__block BOOL intermediate=NO,nearPeak=NO;
  waitUntil(^{NSArray* p=modelPixels(page);if([p[0] unsignedLongValue]<100||[p[1] unsignedLongValue]<100)return NO;
    require(std::abs([p[2] doubleValue]-284.5)<2&&std::abs([p[3] doubleValue]-354.5)<2,"Native pose Main changed horizontal bind placement");
    require(std::abs([p[4] doubleValue]-179.5)<2,"Native pose Main moved the stationary left mesh");
    const double displacement=[p[4] doubleValue]-[p[5] doubleValue];require(displacement>=88&&displacement<=122,"Native pose Main motion exceeded its authored 90..120px range");
    low=std::min(low,displacement);high=std::max(high,displacement);intermediate|=std::abs(displacement-105)<3;nearPeak|=std::abs(displacement-120)<3;
    return BOOL(high-low>10&&intermediate&&nearPeak);
  },3,"Native pose Main did not render both known 105px interpolation and the authored 120px peak");require(!failure,"Native pose Main reported an error");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native pose Main close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native pose Main resources were not released");
  fprintf(stderr,"Main poses %s: explicit clip 7, fixed bind placement, 105px interpolation and 120px peak %.2f..%.2f px passed\n",package?"PKG":"loose",low,high);
}
