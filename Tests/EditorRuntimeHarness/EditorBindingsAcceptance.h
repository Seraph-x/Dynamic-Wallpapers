#pragma once

static NSDictionary* bindingsSnapshot(DWWebPage* page) {
  return command(page,@{@"type":@"snapshot"})[@"document"];
}

static void bindingsSelect(DWWebPage* page,NSInteger identifier) {
  [page editorTestScript:[NSString stringWithFormat:@"document.querySelector('#layers button[data-layer-id=\"%ld\"]').click();",(long)identifier]];
  [page clipTestAwait:@"document.getElementById('bind-color')&&!document.getElementById('bind-color').disabled"];
}

static void bindingsOpen(DWWebPage* page,NSString* field) {
  [page editorTestScript:[NSString stringWithFormat:@"document.getElementById('bind-'+%@).click();",propertyDefinitionsJSON(field)]];
  [page clipTestAwait:@"document.getElementById('property-binding-dialog').open"];
}

static void bindingsChoose(DWWebPage* page,NSString* field,NSString* value) {
  [page clipTestAwait:[NSString stringWithFormat:@"(()=>{const input=document.getElementById('property-binding-'+%@);input.focus();input.value=%@;input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));return input.value===%@;})()",propertyDefinitionsJSON(field),propertyDefinitionsJSON(value),propertyDefinitionsJSON(value)]];
}

static void bindingsClick(DWWebPage* page,NSString* action) {
  [page editorTestScript:[NSString stringWithFormat:@"document.getElementById('property-binding-'+%@).click();",propertyDefinitionsJSON(action)]];
  [page clipTestAwait:@"!document.getElementById('property-binding-dialog').open"];
}

static void bindingsBind(DWWebPage* page,NSString* field,NSString* name,NSString* condition=nil) {
  bindingsOpen(page,field);bindingsChoose(page,@"name",name);
  if(condition)bindingsChoose(page,@"condition",condition);
  bindingsClick(page,@"apply");
}

static void bindingsExpectBlocked(DWWebPage* page,NSString* type) {
  __block BOOL done=NO;__block NSDictionary* reply=nil;__block NSError* failure=nil;
  // Snapshot deliberately has no paths field: protocol rejection must not be
  // mistaken for the workbench's actual modal capture barrier.
  NSDictionary* payload=[type isEqual:@"export-pkg"]?@{@"type":type,@"paths":@[]}:@{@"type":type};
  [page requestEditorCommand:payload completion:^(NSDictionary* result,NSError* error){reply=result;failure=error;done=YES;}];
  waitUntil(^{return done;},6,"Binding modal capture command did not complete");
  NSString* message=[reply[@"error"] isKindOfClass:NSString.class]?reply[@"error"]:nil;
  require(!failure&&[message isEqual:@"Resolve the property binding dialog before saving or exporting."],
          "Binding dialog did not produce its specific native snapshot/export barrier");
}

static void verifyPropertyBindingsWorkbench(DWWebRuntime* runtime,NSString* sourceRoot,NSString* editorRoot,
                                             NSString* cache,NSString* sourceJSON,NSString* expectedJSON) {
  NSDictionary* sourceBytes=previewFileBytes(sourceRoot);
  NSData* sourceJSONBytes=[NSData dataWithContentsOfFile:sourceJSON],*expectedJSONBytes=[NSData dataWithContentsOfFile:expectedJSON];
  NSDictionary* original=clipJSON(sourceJSON),*expected=clipJSON(expectedJSON);
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:sourceRoot runtimeRoot:editorRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Cannot create native binding workbench");
  page.onError=^(NSError* value){failure=value;};
  configureResources(page,[cache stringByAppendingPathComponent:@"BindingResources"],sourceRoot,^(NSError* value){failure=value;});
  NSWindow* window=fkHostWindow(page);[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Native binding workbench first frame timed out");
  require(!failure&&[page editorTestNativeViewIsAttached],"Native binding CEF child failed or is detached");
  command(page,@{@"type":@"thaw"});bindingsSelect(page,1);bindingsOpen(page,@"color");
  [page clipTestAwait:@"document.getElementById('property-binding-current').textContent.trim().length>0"];
  bindingsExpectBlocked(page,@"snapshot");bindingsExpectBlocked(page,@"export-pkg");
  NSDictionary* frozen=command(page,@{@"type":@"freeze"});
  require([frozen[@"dirty"] boolValue]&&[frozen[@"document"] isEqual:original],"Pending binding freeze changed canonical document or lost dirty state");
  command(page,@{@"type":@"thaw"});bindingsClick(page,@"cancel");
  require([bindingsSnapshot(page) isEqual:original],"Binding thaw/cancel did not recover unchanged capture");

  // Confirm with a genuine AppKit Enter event and immediately capture queued
  // Apply. Freeze must await the actual operation, preserving one revision.
  bindingsOpen(page,@"color");bindingsChoose(page,@"name",@"tint");
  [page clipTestAwait:@"(()=>{const button=document.getElementById('property-binding-apply');window.__bindingTrusted=false;button.addEventListener('click',event=>window.__bindingTrusted=event.isTrusted,{once:true});button.focus();return document.activeElement===button;})()"];
  [page clipTestKey:@"\r" code:36];
  frozen=command(page,@{@"type":@"freeze"});
  require([frozen[@"dirty"] boolValue]&&[frozen[@"document"][@"scene"][@"objects"][0][@"color"] isEqual:@{@"value":@"0 1 0",@"user":@"tint"}],"Native freeze overtook queued binding Apply");
  command(page,@{@"type":@"thaw"});[page clipTestAwait:@"window.__bindingTrusted&&!document.getElementById('property-binding-dialog').open"];
  bindingsBind(page,@"alpha",@"opacity");bindingsBind(page,@"visible",@"enabled");
  bindingsSelect(page,2);bindingsBind(page,@"visible",@"mode",@"night");
  bindingsSelect(page,3);bindingsBind(page,@"text",@"caption");bindingsBind(page,@"pointsize",@"fontSize");
  NSDictionary* authored=bindingsSnapshot(page);
  require([authored isEqual:expected],"Actual native forms differ from independent browser binding export");
  for(int i=0;i<6;++i)command(page,@{@"type":@"undo"});
  require([bindingsSnapshot(page) isEqual:original],"Six binding operations did not undo exactly to source");
  for(int i=0;i<6;++i)command(page,@{@"type":@"redo"});
  require([bindingsSnapshot(page) isEqual:authored],"Native binding redo lost exact document metadata");

  bindingsSelect(page,4);bindingsOpen(page,@"color");bindingsChoose(page,@"name",@"tint");
  [page clipTestAwait:@"/script/i.test(document.getElementById('property-binding-warning').textContent)"];
  // Programmatic layer navigation and repeated submission in the same turn
  // exercise captured target identity and synchronous busy protection.
  [page editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"1\"]').click();const button=document.getElementById('property-binding-apply');button.click();button.click();"];
  [page clipTestAwait:@"!document.getElementById('property-binding-dialog').open"];
  NSDictionary* replaced=bindingsSnapshot(page);
  NSMutableDictionary* replacement=[authored mutableCopy],*scene=[authored[@"scene"] mutableCopy];
  NSMutableArray* objects=[scene[@"objects"] mutableCopy];NSMutableDictionary* target=[objects[3] mutableCopy];
  target[@"color"]=@{@"value":@"0 1 0",@"user":@"tint",@"scriptproperties":@{@"future":@YES},@"future":@{@"keep":@"🌙"}};
  objects[3]=target;scene[@"objects"]=objects;replacement[@"scene"]=scene;
  require([replaced isEqual:replacement],"Repeated confirmation changed a different layer or removed unknown wrapper fields");
  command(page,@{@"type":@"undo"});require([bindingsSnapshot(page) isEqual:authored],"Replacement was not one exact undo revision");

  bindingsSelect(page,3);bindingsOpen(page,@"text");bindingsClick(page,@"remove");
  require([bindingsSnapshot(page)[@"scene"][@"objects"][2][@"text"] isEqual:original[@"scene"][@"objects"][2][@"text"]],"Native removal changed literal CRLF/Unicode fallback bytes");
  command(page,@{@"type":@"undo"});require([bindingsSnapshot(page) isEqual:authored],"Native removal undo did not restore full binding");
  bindingsOpen(page,@"text");bindingsChoose(page,@"name",@"e\u0301");bindingsClick(page,@"apply");
  require([bindingsSnapshot(page)[@"scene"][@"objects"][2][@"text"][@"user"] isEqual:@"e\u0301"],"Native selection normalized exact Unicode property name");
  command(page,@{@"type":@"undo"});
  bindingsOpen(page,@"text");
  [page clipTestAwait:@"(()=>{window.__bindingEscape=false;document.addEventListener('keydown',event=>{if(event.key==='Escape')window.__bindingEscape=event.isTrusted;},{once:true});return true;})()"];
  [page clipTestKey:@"\033" code:53];
  [page clipTestAwait:@"!document.getElementById('property-binding-dialog').open&&window.__bindingEscape"];
  require([bindingsSnapshot(page) isEqual:authored],"Native Escape changed the canonical bound document");
  command(page,@{@"type":@"mark-saved",@"document":authored});
  require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native saved binding document remained dirty");
  require(!failure&&[previewFileBytes(sourceRoot) isEqual:sourceBytes]
          &&[[NSData dataWithContentsOfFile:sourceJSON] isEqual:sourceJSONBytes]
          &&[[NSData dataWithContentsOfFile:expectedJSON] isEqual:expectedJSONBytes],"Native binding authoring changed source/export fixture bytes");
  previewClose(page,0,runtime);[window close];
  page=[runtime editorPageWithProjectRoot:sourceRoot runtimeRoot:editorRoot configuration:@{@"language":@"en",@"document":authored} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Cannot reopen saved native binding document");
  page.onError=^(NSError* value){failure=value;};
  configureResources(page,[cache stringByAppendingPathComponent:@"BindingReopenResources"],sourceRoot,^(NSError* value){failure=value;});
  window=fkHostWindow(page);[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Saved native binding document reopen timed out");
  require(!failure,"Saved native binding document failed during reopen");command(page,@{@"type":@"thaw"});
  require([bindingsSnapshot(page) isEqual:authored],"Native saved binding reopen changed exact document");
  require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native reopened saved binding document is dirty");
  previewClose(page,0,runtime);[window close];
  require([previewFileBytes(sourceRoot) isEqual:sourceBytes],"Native saved binding reopen changed source bytes");
  fprintf(stderr,"Native bindings: actual selects, trusted Enter/Escape, modal barriers, queued Apply/freeze, exact target/double submit, Unicode/history, saved reopen and immutable source passed\n");
}

static BOOL bindingsPixels(DWWebPage* page,BOOL direct,BOOL conditional) {
  CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;if(!image)return NO;
  NSData* data=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
  require(data&&CGImageGetBitsPerPixel(image)==32,"Binding GPU frame has unexpected pixel format");
  const auto* bytes=static_cast<const UInt8*>(data.bytes);
  const size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),row=CGImageGetBytesPerRow(image);
  for(int layer=0;layer<2;++layer){
    const size_t center=width*(layer?320:120)/640;
    for(size_t y=height/2-5;y<height/2+5;++y)for(size_t x=center-5;x<center+5;++x){
      const size_t at=y*row+x*4;const bool red=layer==0&&direct,green=layer==1&&conditional;
      if(bytes[at]>15||(red?bytes[at+2]<240:bytes[at+2]>15)||(green?bytes[at+1]<240:bytes[at+1]>15))return NO;
    }
  }
  return YES;
}

static void bindingsAwaitPixels(DWWebPage* page,BOOL direct,BOOL conditional,const char* message) {
  try {waitUntil(^{return bindingsPixels(page,direct,conditional);},4,message);}
  catch(const std::exception& failure){
    CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;
    if(image){
      NSString* path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"editor-bindings-native-gpu.png"];
      NSData* png=[[[NSBitmapImageRep alloc]initWithCGImage:image] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      require(png&&[png writeToFile:path atomically:YES],"Cannot save failed binding GPU frame");
      fprintf(stderr,"Binding GPU failure diagnostic: %s (%s)\n",path.UTF8String,failure.what());
    }
    throw;
  }
}

static void verifyPropertyBindingsPlayback(DWWebRuntime* runtime,NSString* loose,NSString* package,NSString* runtimeRoot) {
  NSDictionary* looseBytes=previewFileBytes(loose),*packageBytes=previewFileBytes(package);
  for(NSNumber* packaged in @[@NO,@YES]){@autoreleasepool{
    NSError* error=nil;__block NSError* failure=nil;
    DWWebPage* page=[runtime scenePageWithProjectRoot:packaged.boolValue?package:loose runtimeRoot:runtimeRoot entry:packaged.boolValue?@"scene.pkg":@"scene.json"
      representation:packaged.boolValue?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
    require(page!=nil,error.localizedDescription.UTF8String ?: "Cannot create native binding export playback");
    page.onError=^(NSError* value){failure=value;};
    page.onSceneScriptIssue=^(NSDictionary* issue){fprintf(stderr,"Binding export script issue: %s\n",issue.description.UTF8String);require(false,"Binding export script failed");};
    require([page setOutputGain:0 error:&error],"Cannot mute native binding playback");
    [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Binding export first GPU frame timed out");
    require(!failure,"Binding export playback failed");
    bindingsAwaitPixels(page,NO,NO,"Default false/direct and unmatched combo did not hide target GPU pixels");
    previewVerifyNativeAuthoringDenied(page);
    // The fixture's actual SceneScript reads thisScene.getLayer(), observing
    // the renderer's layer state rather than re-decoding source declarations.
    NSDictionary* initial=[page previewTestValue:@"new Promise(resolve=>{const end=performance.now()+4000;const check=()=>{if(globalThis.__bindingTextProbe)resolve(globalThis.__bindingTextProbe);else if(performance.now()>end)resolve({});else requestAnimationFrame(check);};check();})"];
    require([initial[@"text"] isEqual:@"Authored 雪"]&&[initial[@"pointsize"] isEqual:@40],"Actual renderer layer did not resolve bound initial text/point size");
    editorPropertiesDeliver(page,@{@"enabled":@YES,@"opacity":@1,@"tint":@"1 0 0",@"mode":@"night",@"caption":@"Native caption 雪",@"fontSize":@48});
    bindingsAwaitPixels(page,YES,YES,"Live bindings did not produce direct red and conditional green GPU pixels");
    // The pinned engine supports these two bindings at load time only. A
    // live property command must not be reported as changing actual text/font.
    NSDictionary* live=[page previewTestValue:@"globalThis.__bindingTextProbe"];
    require([live[@"text"] isEqual:@"Authored 雪"]&&[live[@"pointsize"] isEqual:@40],"Pinned text/font load-time capability boundary changed unexpectedly");
    editorPropertiesDeliver(page,@{@"mode":@"day"});
    bindingsAwaitPixels(page,YES,NO,"Live combo day did not hide only the conditional GPU target");
    require(!failure,"Native binding playback reported a runtime error");previewClose(page,0,runtime);
    fprintf(stderr,"Main %s bindings: actual hidden/default and live red/green GPU pixels, conditional toggle and actual load-time text/font state (unchanged by live patch) passed\n",packaged.boolValue?"PKG":"loose");
  }}
  require([previewFileBytes(loose) isEqual:looseBytes]&&[previewFileBytes(package) isEqual:packageBytes],"Binding playback changed loose/PKG source bytes");
}
