#pragma once

static NSString* propertyDefinitionsJSON(id value) {
  NSError* error=nil;
  NSData* bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:&error];
  require(bytes!=nil,error.localizedDescription.UTF8String ?: "Cannot encode property definition input");
  return [[NSString alloc]initWithData:bytes encoding:NSUTF8StringEncoding];
}

// Exercise the actual form listeners. There is no test-only mutation of the
// editor document, property catalog, validation, or transaction queue.
static void propertyDefinitionsInput(DWWebPage* page,NSString* name,NSString* value) {
  NSString* script=[NSString stringWithFormat:@"(()=>{const input=document.getElementById('user-property-'+%@);input.focus();input.value=%@;input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));return true;})()",propertyDefinitionsJSON(name),propertyDefinitionsJSON(value)];
  [page clipTestAwait:script];
}

static void propertyDefinitionsClick(DWWebPage* page,NSString* name) {
  [page editorTestScript:[NSString stringWithFormat:@"document.getElementById('user-property-'+%@).click();",propertyDefinitionsJSON(name)]];
  [page clipTestAwait:@"!document.getElementById('project-panel').inert"];
}

static NSDictionary* propertyDefinitionsSnapshot(DWWebPage* page) {
  return command(page,@{@"type":@"snapshot"})[@"document"];
}

static void propertyDefinitionsExpectBlocked(DWWebPage* page,NSString* type) {
  __block BOOL done=NO;__block NSDictionary* reply=nil;__block NSError* failure=nil;
  NSDictionary* payload=[type isEqual:@"export-pkg"]?@{@"type":type,@"paths":@[]}:@{@"type":type};
  [page requestEditorCommand:payload completion:^(NSDictionary* result,NSError* error){reply=result;failure=error;done=YES;}];
  waitUntil(^{return done;},6,"Pending property draft command did not complete");
  NSString* message=[reply[@"error"] isKindOfClass:NSString.class]?reply[@"error"]:nil;
  const BOOL propertyBarrier=[message isEqual:@"Resolve the property confirmation dialog before saving or exporting."]
    ||[message isEqual:@"Correct the property draft or revert it before continuing."]
    ||[message hasPrefix:@"Invalid property declaration:"];
  require(!failure&&propertyBarrier,
          "Pending property draft/dialog did not reject native snapshot/export");
}

static void propertyDefinitionsCreate(DWWebPage* page,NSString* name,NSString* value) {
  propertyDefinitionsClick(page,@"new");
  propertyDefinitionsInput(page,@"key",name);
  propertyDefinitionsInput(page,@"type",@"textinput");
  propertyDefinitionsInput(page,@"value",value);
  propertyDefinitionsClick(page,@"apply");
}

static void verifyPropertyDefinitionsWorkbench(DWWebRuntime* runtime,NSString* sourceRoot,NSString* editorRoot,NSString* cache) {
  NSDictionary* sourceBytes=previewFileBytes(sourceRoot);
  NSDictionary* scene=clipJSON([sourceRoot stringByAppendingPathComponent:@"scene.json"]);
  NSMutableDictionary* project=[clipJSON([sourceRoot stringByAppendingPathComponent:@"project.json"]) mutableCopy];
  NSMutableDictionary* general=[project[@"general"] mutableCopy];
  [general removeObjectForKey:@"properties"];project[@"general"]=general;[project removeObjectForKey:@"preset"];
  NSDictionary* original=@{@"title":@"Native property definition authoring",@"entry":@"scene.json",@"project":project,@"scene":scene};
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:sourceRoot runtimeRoot:editorRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Cannot create property definition workbench");
  page.onError=^(NSError* value){failure=value;};
  configureResources(page,[cache stringByAppendingPathComponent:@"DefinitionResources"],sourceRoot,^(NSError* value){failure=value;});
  NSWindow* window=fkHostWindow(page);[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Property definition workbench first frame timed out");
  require(!failure&&[page editorTestNativeViewIsAttached],"Property definition CEF child failed or is detached");
  command(page,@{@"type":@"thaw"});
  [page editorTestScript:@"document.getElementById('project-workspace').click();"];
  [page clipTestAwait:@"!document.getElementById('project-panel').hidden&&document.getElementById('user-property-list').value==='' "];
  require([propertyDefinitionsSnapshot(page) isEqual:original],"Opening empty Project workspace changed the document");

  // These two exact names compare canonically equal in Swift, but must remain
  // two independent JSON keys all the way through the native capture bridge.
  propertyDefinitionsCreate(page,@"\u00e9",@"composed-native");
  propertyDefinitionsCreate(page,@"e\u0301",@"decomposed-native");
  NSDictionary* exact=propertyDefinitionsSnapshot(page)[@"project"][@"general"][@"properties"];
  require(exact.count==2&&[exact[@"\u00e9"][@"value"] isEqual:@"composed-native"]&&[exact[@"e\u0301"][@"value"] isEqual:@"decomposed-native"],
          "Native new-project authoring collapsed distinct Unicode property names");

  propertyDefinitionsClick(page,@"new");propertyDefinitionsInput(page,@"key",@"speed");
  propertyDefinitionsInput(page,@"type",@"slider");propertyDefinitionsInput(page,@"value",@"2.5");
  propertyDefinitionsInput(page,@"min",@"0");propertyDefinitionsInput(page,@"max",@"5");
  // Queue Apply then immediately issue native freeze: both must participate in
  // the real operation queue, so freeze captures one complete definition.
  [page editorTestScript:@"document.getElementById('user-property-apply').click();"];
  NSDictionary* frozen=command(page,@{@"type":@"freeze"});
  NSDictionary* saved=frozen[@"document"];
  require([frozen[@"dirty"] boolValue]&&[saved[@"project"][@"general"][@"properties"][@"speed"][@"value"] isEqual:@2.5],
          "Native freeze overtook queued property Apply");
  command(page,@{@"type":@"thaw"});
  // Real AppKit key events leave a focused, unblurred valid draft. Capture must
  // flush it without requiring Apply, blur, or an authoring command shortcut.
  [page clipTestAwait:@"(()=>{const input=document.getElementById('user-property-value');input.focus();input.select();window.__propertyInputTrusted=false;input.addEventListener('input',event=>{if(event.isTrusted)window.__propertyInputTrusted=true;});return document.activeElement===input;})()"];
  [page editorTestType:@"4"];
  [page editorTestAwaitInput:@"#user-property-value" value:@"4" focused:YES];
  [page clipTestAwait:@"window.__propertyInputTrusted"];
  frozen=command(page,@{@"type":@"freeze"});saved=frozen[@"document"];
  require([saved[@"project"][@"general"][@"properties"][@"speed"][@"value"] isEqual:@4],"Native freeze did not flush focused property default");
  command(page,@{@"type":@"mark-saved",@"document":saved});
  require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Saved property definitions remained dirty");
  command(page,@{@"type":@"thaw"});

  propertyDefinitionsInput(page,@"value",@"6");propertyDefinitionsClick(page,@"apply");
  [page clipTestAwait:@"document.getElementById('user-property-error').textContent.trim().length>0"];
  propertyDefinitionsExpectBlocked(page,@"snapshot");propertyDefinitionsExpectBlocked(page,@"export-pkg");
  frozen=command(page,@{@"type":@"freeze"});
  require([frozen[@"dirty"] boolValue]&&[frozen[@"document"] isEqual:saved],"Invalid native draft changed canonical capture or lost dirty state");
  command(page,@{@"type":@"thaw"});propertyDefinitionsClick(page,@"revert");
  require([propertyDefinitionsSnapshot(page) isEqual:saved],"Invalid draft revert changed saved definitions");

  propertyDefinitionsClick(page,@"delete");
  [page clipTestAwait:@"document.getElementById('user-property-delete-dialog').open"];
  propertyDefinitionsExpectBlocked(page,@"snapshot");propertyDefinitionsExpectBlocked(page,@"export-pkg");
  frozen=command(page,@{@"type":@"freeze"});
  require([frozen[@"dirty"] boolValue]&&[frozen[@"document"] isEqual:saved],"Pending deletion changed canonical property definitions");
  command(page,@{@"type":@"thaw"});propertyDefinitionsClick(page,@"delete-cancel");
  [page clipTestAwait:@"!document.getElementById('user-property-delete-dialog').open"];
  require([propertyDefinitionsSnapshot(page) isEqual:saved],"Thaw/cancel did not restore native property capture");
  command(page,@{@"type":@"undo"});
  require([propertyDefinitionsSnapshot(page)[@"project"][@"general"][@"properties"][@"speed"][@"value"] isEqual:@2.5],"Native property draft was not one undo revision");
  command(page,@{@"type":@"redo"});require([propertyDefinitionsSnapshot(page) isEqual:saved],"Native property redo lost exact definitions");
  require(!failure&&[previewFileBytes(sourceRoot) isEqual:sourceBytes],"Native property authoring changed captured source files");
  previewClose(page,0,runtime);[window close];
  fprintf(stderr,"Native property definitions: empty-project exact Unicode names, queued Apply/freeze, trusted focused keyboard flush, invalid snapshot/export barriers, modal thaw/cancel and history passed\n");
}

static NSDictionary* propertyDefinitionsDefaults() {
  NSMutableDictionary* expected=[editorPropertiesDefaults() mutableCopy];
  expected[@"tint"]=@[@1,@0,@0];expected[@"caption"]=@"雪 & <text>";
  expected[@"authored-é"]=@"composed";expected[@"authored-e\u0301"]=@"decomposed";
  expected[@"authored"]=@4;expected[@"copied"]=@4;expected[@"flag"]=@NO;
  expected[@"paint"]=@{@"x":@0.2,@"y":@0.4,@"z":@0.6};expected[@"options"]=@"first";
  return expected;
}

static BOOL propertyDefinitionsDefaultPixels(DWWebPage* page) {
  CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;if(!image)return NO;
  NSData* data=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
  require(data&&CGImageGetBitsPerPixel(image)==32,"Property definition GPU frame has an unexpected format");
  const auto* bytes=static_cast<const UInt8*>(data.bytes);
  const size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),rowBytes=CGImageGetBytesPerRow(image);
  // Browser-authored tint is red; the separate callback remains green because
  // the other original scalar defaults do not satisfy its red predicate.
  for(const size_t center:{width*120/640,width/2})for(size_t y=height/2-5;y<height/2+5;++y)for(size_t x=center-5;x<center+5;++x){
    const size_t at=y*rowBytes+x*4;const bool red=center==width*120/640;
    if(bytes[at]>15||(red?bytes[at+2]<240||bytes[at+1]>15:bytes[at+1]<240||bytes[at+2]>15))return NO;
  }
  return YES;
}

static void propertyDefinitionsAssertDefaults(DWWebPage* page) {
  NSDictionary* probe=editorPropertiesRead(page),*actual=probe[@"values"],*expected=propertyDefinitionsDefaults();
  for(NSString* key in expected){
    id value=actual[key],oracle=expected[key];
    if([key isEqual:@"paint"]){
      require([value isKindOfClass:NSDictionary.class],"Authored color default was not delivered as a runtime Vec3");
      for(NSString* component in @[@"x",@"y",@"z"])require(value[component]!=nil&&std::abs([value[component] doubleValue]-[oracle[component] doubleValue])<0.00001,"Authored color default differs from exact fixture expectation");
    }else require([value isEqual:oracle],"Browser-authored definition default differs in actual native callback");
  }
  require([probe[@"top"] isEqual:@1]&&[probe[@"init"] isEqual:@1]&&[probe[@"apply"] integerValue]>0,"Authored property callback did not initialize exactly once");
  require([probe[@"noOpener"] boolValue]&&[probe[@"noAuthoring"] boolValue]&&![page scriptTestHasEditorSession],"Definition export playback acquired editor capabilities");
}

static void verifyPropertyDefinitionsPlayback(DWWebRuntime* runtime,NSString* loose,NSString* package,NSString* runtimeRoot) {
  NSDictionary* looseBytes=previewFileBytes(loose),*packageBytes=previewFileBytes(package);
  for(NSNumber* packaged in @[@NO,@YES]){
    @autoreleasepool {
      NSError* error=nil;__block NSError* failure=nil;
      DWWebPage* page=[runtime scenePageWithProjectRoot:packaged.boolValue?package:loose runtimeRoot:runtimeRoot entry:packaged.boolValue?@"scene.pkg":@"scene.json"
        representation:packaged.boolValue?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
      require(page!=nil,error.localizedDescription.UTF8String ?: "Cannot create authored property export playback");
      page.onError=^(NSError* value){failure=value;};
      page.onSceneScriptIssue=^(NSDictionary* issue){fprintf(stderr,"Definition export issue: %s\n",issue.description.UTF8String);require(false,"Authored property export SceneScript failed");};
      require([page setOutputGain:0 error:&error],"Cannot mute definition export playback");
      [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Definition export first GPU frame timed out");
      require(!failure,"Definition export playback failed");
      waitUntil(^{return propertyDefinitionsDefaultPixels(page);},4,"Authored default did not produce independent green callback/red direct-bound GPU pixels");
      propertyDefinitionsAssertDefaults(page);previewVerifyNativeAuthoringDenied(page);
      editorPropertiesDeliver(page,editorPropertiesChanges());editorPropertiesAwait(page,YES);
      require([editorPropertiesRead(page)[@"values"][@"authored-é"] isEqual:@"composed"]&&[editorPropertiesRead(page)[@"values"][@"authored-e\u0301"] isEqual:@"decomposed"],"Runtime update erased authored exact Unicode defaults");
      previewClose(page,0,runtime);
      fprintf(stderr,"Main %s definition export: authored scalar defaults, exact Unicode, real callback/direct binding GPU pixels and live updates passed\n",packaged.boolValue?"PKG":"loose");
    }
  }
  require([previewFileBytes(loose) isEqual:looseBytes]&&[previewFileBytes(package) isEqual:packageBytes],"Definition export playback changed project/source bytes");
}
