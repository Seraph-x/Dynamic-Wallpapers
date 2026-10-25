#pragma once

static NSDictionary* mixingExpectedDocument(NSDictionary* original) {
  NSMutableDictionary* expected=[original mutableCopy],*scene=[original[@"scene"] mutableCopy];
  NSMutableArray* objects=[scene[@"objects"] mutableCopy];NSMutableDictionary* object=[objects[0] mutableCopy];
  NSMutableArray* layers=[object[@"animationlayers"] mutableCopy];NSMutableDictionary* overlay=[layers[1] mutableCopy];
  overlay[@"blend"]=@.25;layers[1]=overlay;object[@"animationlayers"]=layers;objects[0]=object;scene[@"objects"]=objects;expected[@"scene"]=scene;return expected;
}

static void verifyMixingWorkbench(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,NSString* resources) {
  NSDictionary* original=@{@"title":@"Native mixing",@"entry":@"scene.json",@"project":clipJSON([projectRoot stringByAppendingPathComponent:@"project.json"]),@"scene":clipJSON([projectRoot stringByAppendingPathComponent:@"scene.json"])};
  NSArray* fixtureLayers=@[
    @{@"name":@"Base",@"animation":@7,@"blend":@1,@"rate":@1,@"visible":@YES,@"additive":@NO,@"future":@{@"kept":@"base"}},
    @{@"name":@"Overlay",@"animation":@11,@"blend":@.5,@"rate":@1,@"visible":@YES,@"additive":@NO,@"future":@{@"kept":@"overlay"}},
    @{@"name":@"Hidden",@"animation":@7,@"blend":@1,@"rate":@1,@"visible":@NO,@"additive":@NO,@"future":@{@"kept":@"hidden"}}];
  NSArray* objects=original[@"scene"][@"objects"];
  require(objects.count==1&&[objects[0][@"id"] isEqual:@1]&&[objects[0][@"animationlayers"] isEqual:fixtureLayers],"Native mixing export must retain the exact ordered native table and unknown metadata");
  NSString* modelPath=[projectRoot stringByAppendingPathComponent:@"models/editor/rig.mdl"];
  NSData* originalBytes=[NSData dataWithContentsOfFile:modelPath];require(originalBytes!=nil,"Native mixing exported MDL is missing");
  NSString* originalHash=resourceHash(originalBytes);
  require(originalBytes.length>21&&std::memcmp(originalBytes.bytes,"MDLV0023",8)==0&&clipU32(originalBytes,clipSection(originalBytes,@"MDLA0006")+13)==2,"Native mixing fixture must contain its two actual native clips");
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native mixing workbench creation failed");
  page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});
  NSWindow* window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1180,760) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;page.view.frame=window.contentView.bounds;[window.contentView addSubview:page.view];[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native mixing first frame timed out");require(!failure,"Native mixing workbench failed");
  require([page editorTestNativeViewIsAttached],"Native mixing CEF child is detached");command(page,@{@"type":@"thaw"});
  [page editorTestScript:@"(()=>{document.querySelector('#layers button[data-layer-id=\"1\"]').click();})();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"(()=>{document.getElementById('model-workspace').click();})();"];command(page,@{@"type":@"snapshot"});
  [page clipTestAwait:@"(()=>{const select=document.getElementById('model-mix-select');return select&&select.options.length===3&&!select.disabled;})()"];
  [page editorTestScript:@"(()=>{document.getElementById('model-mixing-details').open=true;const select=document.getElementById('model-mix-select');select.value='1';select.dispatchEvent(new Event('change',{bubbles:true}));})();"];
  [page clipTestAwait:@"document.getElementById('model-mix-select').value==='1'&&document.getElementById('model-mix-blend').value==='0.5'&&!document.getElementById('model-mix-blend').disabled"];
  fprintf(stderr,"Native mixing phase=trusted-focused-typing\n");
  [page editorTestScript:@"(()=>{const input=document.getElementById('model-mix-blend');input.scrollIntoView({block:'center'});input.focus();input.select();window.__mixTypedTrusted=false;input.addEventListener('input',event=>{window.__mixTypedTrusted=event.isTrusted;},{once:true});})();"];
  [page editorTestAwaitInput:@"#model-mix-blend" value:@"0.5" focused:YES];[page editorTestType:@"0.25"];
  [page editorTestAwaitInput:@"#model-mix-blend" value:@"0.25" focused:YES];[page clipTestAwait:@"window.__mixTypedTrusted"];
  NSDictionary* frozen=command(page,@{@"type":@"freeze"}),*saved=frozen[@"document"],*expected=mixingExpectedDocument(original);
  require([frozen[@"dirty"] boolValue]&&[saved isEqual:expected],"Native mixing focused freeze did not change precisely the second row's blend and preserve the complete document");
  require(saved[@"resourceOverrides"]==nil,"Native table-only mixing edit unexpectedly created a resource override");
  NSArray* staged=[NSFileManager.defaultManager contentsOfDirectoryAtPath:resources error:&error];
  require(staged!=nil,error.localizedDescription.UTF8String ?: "Cannot inspect native mixing resource staging");require(staged.count==0,"Native table-only mixing edit staged MDL bytes");
  NSData* retained=[NSData dataWithContentsOfFile:modelPath];require([retained isEqualToData:originalBytes]&&[resourceHash(retained) isEqual:originalHash],"Native table-only mixing edit changed original MDL bytes or hash");
  fprintf(stderr,"Native mixing phase=save-and-atomic-history\n");
  command(page,@{@"type":@"mark-saved",@"document":saved});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native mixing save acknowledgement remained dirty");
  command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native mixing undo did not restore the entire original native table");
  command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native mixing redo lost the exact JSON-only revision");
  fprintf(stderr,"Native mixing phase=persistent-table-pixels\n");
  [page clipTestAwait:@"(()=>{const playback=document.getElementById('playback');if(playback.getAttribute('aria-pressed')==='true')playback.click();return playback.getAttribute('aria-pressed')==='false';})()"];
  [page editorTestScript:@"(()=>{document.getElementById('timeline-toggle').click();})();"];[page clipTestAwait:@"!document.getElementById('timeline').hidden"];
  [page clipTestAwait:@"(()=>{const canvas=document.querySelector('#canvas canvas'),gl=canvas.getContext('webgl2');window.__mixPixels=null;window.__mixRestore=[];for(const name of ['drawElements','drawArrays']){const original=gl[name];window.__mixRestore.push(()=>gl[name]=original);gl[name]=function(...args){const result=original.apply(this,args),bytes=new Uint8Array(canvas.width*canvas.height*4),counts=[0,0],xs=[0,0],ys=[0,0];gl.readPixels(0,0,canvas.width,canvas.height,gl.RGBA,gl.UNSIGNED_BYTE,bytes);for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){const at=(y*canvas.width+x)*4;if(bytes[at]<70&&bytes[at+1]>180&&bytes[at+2]<70){const half=x<canvas.width/2?0:1;counts[half]++;xs[half]+=x;ys[half]+=y;}}if(counts.every(n=>n>100)){const scale=(xs[1]/counts[1]-xs[0]/counts[0])/70;window.__mixPixels={displacement:(ys[1]/counts[1]-ys[0]/counts[0])/scale,leftY:ys[0]/counts[0],scale};}return result;};}return true;})()"];
  require(std::abs([command(page,@{@"type":@"seek",@"time":@0})[@"time"] doubleValue])<1e-8,"Native mixing seek did not acknowledge 0s");
  NSDictionary* initial=[page clipTestAwait:@"window.__mixPixels&&window.__mixPixels.scale>0&&Math.abs(window.__mixPixels.displacement-22.5)<1.5&&window.__mixPixels"][@"value"];
  require(std::abs([command(page,@{@"type":@"seek",@"time":@.5})[@"time"] doubleValue]-.5)<1e-8,"Native mixing seek did not acknowledge 0.5s");
  NSDictionary* pose=[page clipTestAwait:@"window.__mixPixels&&window.__mixPixels.scale>0&&Math.abs(window.__mixPixels.displacement-52.5)<1.5&&Math.abs(Number(document.getElementById('timeline-time').value)-.5)<1e-8&&window.__mixPixels"][@"value"];
  require(std::abs([pose[@"displacement"] doubleValue]-52.5)<1.5,"Native persistent mixed table did not render 52.5px at 0.5s");
  require(std::abs([pose[@"leftY"] doubleValue]-[initial[@"leftY"] doubleValue])/[pose[@"scale"] doubleValue]<1.5,"Native persistent mixed table moved the stationary left mesh");
  [page editorTestScript:@"(()=>{for(const restore of window.__mixRestore)restore();delete window.__mixRestore;delete window.__mixPixels;})();"];
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native mixed-table playback changed document content");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native mixing editor close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native mixing editor resources were not released");[window close];
  fprintf(stderr,"Native mixing: trusted focused JSON-only freeze, exact table/history/hash, save and actual persistent-table pixels passed\n");
}

static void verifyMixingExport(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,BOOL package) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native mixing Main page creation failed");page.onError=^(NSError* value){failure=value;};[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Native mixing Main first frame timed out");require(!failure,"Native mixing Main rendering failed");
  __block double low=1e9,high=-1e9;__block BOOL intermediate=NO,nearPeak=NO;
  waitUntil(^{NSArray* p=modelPixels(page);if([p[0] unsignedLongValue]<100||[p[1] unsignedLongValue]<100)return NO;
    require(std::abs([p[2] doubleValue]-284.5)<2&&std::abs([p[3] doubleValue]-354.5)<2,"Native mixing Main changed horizontal bind placement");
    require(std::abs([p[4] doubleValue]-179.5)<2,"Native mixing Main moved the stationary left mesh");
    const double displacement=[p[4] doubleValue]-[p[5] doubleValue];require(displacement>=43&&displacement<=107,"Native mixing Main motion exceeded its authored 45..105px range");
    low=std::min(low,displacement);high=std::max(high,displacement);intermediate|=std::abs(displacement-75)<3;nearPeak|=std::abs(displacement-105)<3;
    return BOOL(high-low>10&&intermediate&&nearPeak);
  },3,"Native mixing Main did not render both known 75px interpolation and the authored 105px peak");require(!failure,"Native mixing Main reported an error");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native mixing Main close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native mixing Main resources were not released");
  fprintf(stderr,"Main mixing %s: persistent ordered table, fixed bind placement, 75px interpolation and 105px peak %.2f..%.2f px passed\n",package?"PKG":"loose",low,high);
}
