#pragma once

// Acknowledgement must come from the actual native scene command transport.
static void editorPropertiesDeliver(DWWebPage* page, NSDictionary* values) {
  __block BOOL done=NO;
  __block NSError* failure=nil;
  [page setSceneUserProperties:values completion:^(NSError* error){failure=error;done=YES;}];
  waitUntil(^{return done;},6,"Native user-properties command acknowledgement timed out");
  require(!failure,failure.localizedDescription.UTF8String ?: "Native user-properties command failed");
}

static void editorPropertiesDeliverJSON(DWWebPage* page, NSData* values) {
  __block BOOL done=NO;
  __block NSError* failure=nil;
  [page setSceneUserPropertiesJSONData:values completion:^(NSError* error){failure=error;done=YES;}];
  waitUntil(^{return done;},6,"Native JSON user-properties command acknowledgement timed out");
  require(!failure,failure.localizedDescription.UTF8String ?: "Native JSON user-properties command failed");
}

static void editorPropertiesRejectJSON(DWWebPage* page, NSString* json) {
  __block BOOL done=NO;
  __block NSError* failure=nil;
  [page setSceneUserPropertiesJSONData:[json dataUsingEncoding:NSUTF8StringEncoding]
                          completion:^(NSError* error){failure=error;done=YES;}];
  waitUntil(^{return done;},6,"Invalid JSON property command did not complete");
  require(failure!=nil,"Native JSON property setter accepted malformed/non-object/nested data");
}

static NSDictionary* editorPropertiesRead(DWWebPage* page) {
  return [page previewTestValue:@"globalThis.__propertyProbe"];
}

static NSDictionary* editorPropertiesDefaults() {
  return @{@"enabled":@YES,@"amount":@0.25,@"tint":@"0 1 0",@"caption":@"Initial caption",@"mode":@"quiet",@"\u00e9":@"composed-default",@"e\u0301":@"decomposed-default"};
}

static NSDictionary* editorPropertiesChanges() {
  return @{@"enabled":@NO,@"amount":@0.75,@"tint":@"1 0 0",@"caption":@"",@"mode":@"loud",@"\u00e9":@"composed-live",@"e\u0301":@"decomposed-live"};
}

static void editorPropertiesAssertValues(DWWebPage* page, BOOL changed) {
  NSDictionary* probe=editorPropertiesRead(page),*actual=probe[@"values"];
  NSMutableDictionary* expected=[(changed?editorPropertiesChanges():editorPropertiesDefaults()) mutableCopy];
  expected[@"tint"]=changed?@[@1,@0,@0]:@[@0,@1,@0];
  for(NSString* key in expected)
    require([actual[key] isEqual:expected[key]],"Actual SceneScript property callback value differs from authored expectation");
  require([probe[@"top"] integerValue]==1&&[probe[@"init"] integerValue]==1,
          "Property update remounted or reinitialized the actual SceneScript source");
  require([probe[@"noOpener"] boolValue]&&[probe[@"noAuthoring"] boolValue]&&![page scriptTestHasEditorSession],
          "Property preview acquired an opener or authoring capability");
}

static BOOL editorPropertiesPixels(DWWebPage* page, BOOL changed) {
  CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;
  if(!image)return NO;
  NSData* data=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
  require(data&&CGImageGetBitsPerPixel(image)==32,"Property GPU pixel image has an unexpected format");
  const auto* bytes=static_cast<const UInt8*>(data.bytes);
  const size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),rowBytes=CGImageGetBytesPerRow(image);
  for(const size_t center:{width*120/640,width/2})for(size_t y=height/2-5;y<height/2+5;++y)
    for(size_t x=center-5;x<center+5;++x){
      const size_t at=y*rowBytes+x*4;
      if(bytes[at]>15||(changed?bytes[at+2]<240||bytes[at+1]>15:bytes[at+1]<240||bytes[at+2]>15))return NO;
    }
  return YES;
}

static void editorPropertiesAwait(DWWebPage* page, BOOL changed) {
  waitUntil(^{return editorPropertiesPixels(page,changed);},4,"Actual callback/bound property GPU pixels did not change");
  editorPropertiesAssertValues(page,changed);
}

static void editorPropertiesReject(DWWebPage* page, NSDictionary* values) {
  __block BOOL done=NO;
  __block NSError* failure=nil;
  [page setSceneUserProperties:values completion:^(NSError* error){failure=error;done=YES;}];
  waitUntil(^{return done;},6,"Invalid property command did not complete");
  require(failure!=nil,"Native property setter accepted nested/null/nonfinite values");
}

static DWWebPage* editorPropertiesStart(DWWebRuntime* runtime,NSString* project,NSString* runtimeRoot,BOOL package) {
  NSError* error=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:project runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json"
    representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Property scene creation failed");
  __block NSError* failure=nil;
  page.onError=^(NSError* value){failure=value;};
  page.onSceneScriptIssue=^(NSDictionary* issue){fprintf(stderr,"Actual property SceneScript issue: %s\n",issue.description.UTF8String);require(false,"Property fixture SceneScript failed");};
  require([page setOutputGain:0 error:&error],"Cannot mute native property fixture");
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Property scene first actual GPU frame timed out");
  require(!failure,failure.localizedDescription.UTF8String ?: "Property scene failed");
  previewVerifyNativeAuthoringDenied(page);
  editorPropertiesAwait(page,NO);
  return page;
}

static void editorPropertiesPlayback(DWWebRuntime* runtime,NSString* loose,NSString* package,
                                     NSString* previewRoot,NSString* mainRoot) {
  NSDictionary* looseBytes=previewFileBytes(loose),*packageBytes=previewFileBytes(package);
  DWWebPage* page=editorPropertiesStart(runtime,loose,previewRoot,NO);
  editorPropertiesReject(page,@{@"enabled":@{ @"value":@YES }});
  editorPropertiesReject(page,@{@"amount":@(NAN)});
  editorPropertiesReject(page,@{@"caption":NSNull.null});
  for(NSString* invalidJSON in @[@"{",@"[]",@"null",@"{\"enabled\":{\"value\":true}}"])
    editorPropertiesRejectJSON(page,invalidJSON);
  editorPropertiesAssertValues(page,NO);
  editorPropertiesDeliver(page,editorPropertiesChanges());editorPropertiesAwait(page,YES);
  // NSData preserves two different authored UTF-8 names which Swift String
  // equality considers canonically equivalent. Exercise the real native entry.
  editorPropertiesDeliverJSON(page,[@"{\"\u00e9\":\"first-json-live\",\"e\\u0301\":\"second-json-live\"}" dataUsingEncoding:NSUTF8StringEncoding]);
  NSDictionary* exact=editorPropertiesRead(page)[@"values"];
  require([exact[@"\u00e9"] isEqual:@"first-json-live"]&&[exact[@"e\u0301"] isEqual:@"second-json-live"],
          "Native JSON property entry collapsed two distinct canonical-equivalent authored names");
  NSData* reset=[NSJSONSerialization dataWithJSONObject:editorPropertiesDefaults() options:0 error:nil];
  require(reset!=nil,"Cannot encode complete exact-name property reset");
  editorPropertiesDeliverJSON(page,reset);editorPropertiesAwait(page,NO);
  editorPropertiesDeliver(page,editorPropertiesChanges());editorPropertiesAwait(page,YES);
  const NSInteger applied=[editorPropertiesRead(page)[@"apply"] integerValue];
  editorPropertiesDeliver(page,editorPropertiesChanges());editorPropertiesAwait(page,YES);
  require([editorPropertiesRead(page)[@"apply"] integerValue]>applied,"Repeated actual property patch did not reach SceneScript");
  previewPlaying(page,NO);runFor(.06);
  NSDictionary* paused=editorPropertiesRead(page);
  editorPropertiesDeliver(page,editorPropertiesDefaults());editorPropertiesAwait(page,NO);
  NSDictionary* repainted=editorPropertiesRead(page);
  fprintf(stderr,"Property last displayed clock %.9f; actual paused forced-frame clock %.9f\n",[paused[@"runtime"] doubleValue],[repainted[@"runtime"] doubleValue]);
  require([repainted[@"frames"] integerValue]>[paused[@"frames"] integerValue],"Paused property change did not render a real frame");
  runFor(.1);
  require([editorPropertiesRead(page)[@"frames"] integerValue]==[repainted[@"frames"] integerValue],"Property repaint resumed paused scene");
  editorPropertiesDeliver(page,editorPropertiesChanges());editorPropertiesAwait(page,YES);
  require([editorPropertiesRead(page)[@"runtime"] doubleValue]==[repainted[@"runtime"] doubleValue],"Repeated paused property patch changed time");
  previewPlaying(page,YES);runFor(.12);
  require([editorPropertiesRead(page)[@"runtime"] doubleValue]>[repainted[@"runtime"] doubleValue],"Property preview did not resume its actual clock");
  NSString* oldOrigin=page.origin;
  previewClose(page,0,runtime);
  require(page.onSceneScriptIssue==nil,"Closed property preview retained a SceneScript callback");
  page=editorPropertiesStart(runtime,loose,previewRoot,NO);
  require(![page.origin isEqual:oldOrigin],"Property restart reused the previous origin");
  editorPropertiesAssertValues(page,NO);previewClose(page,0,runtime);
  for(NSNumber* packaged in @[@NO,@YES]){
    @autoreleasepool {
      page=editorPropertiesStart(runtime,packaged.boolValue?package:loose,mainRoot,packaged.boolValue);
      editorPropertiesDeliver(page,editorPropertiesChanges());editorPropertiesAwait(page,YES);
      editorPropertiesDeliver(page,editorPropertiesDefaults());editorPropertiesAwait(page,NO);
      previewClose(page,0,runtime);
      fprintf(stderr,"Main %s live properties actual callback/bound GPU playback passed\n",packaged.boolValue?"PKG":"loose");
    }
  }
  require([previewFileBytes(loose) isEqual:looseBytes]&&[previewFileBytes(package) isEqual:packageBytes],
          "Property preview/Main playback changed captured project or exported source bytes");
  fprintf(stderr,"Native properties: five exact types, repeated real callbacks, paused GPU repaint/frozen clock, resume, fresh-origin defaults, immutable loose/PKG bytes and complete page release passed\n");
}
