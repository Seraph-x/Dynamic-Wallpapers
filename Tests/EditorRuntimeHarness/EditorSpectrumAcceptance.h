#pragma once

// This is a deterministic native data-path test. It does not capture OS audio.
static NSString* editorSpectrumSource() {
  return [NSString stringWithUTF8String:R"JS(
const host=({}).constructor.constructor('return globalThis')();
let audio;
export function init(value){
  audio=engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_64);
  host.__nativeSpectrum={frames:0,noOpener:host.opener===null,
    noAuthoring:!['__dynamicWallpaperEditor','__editor','__editorConfiguration','__editorSession'].some(key=>key in host)};
  return value;
}
export function update(value){
  const state=host.__nativeSpectrum;
  state.frames++;state.runtime=engine.runtime;
  state.left=Array.from(audio.left);state.right=Array.from(audio.right);state.average=Array.from(audio.average);
  return new Vec3(audio.left[7]===1?1:0,audio.right[19]===1?1:0,audio.average[31]===0.5?1:0);
}
)JS"];
}

static void editorSpectrumWriteFixture(NSString* root) {
  NSDictionary* scene=@{@"general":@{@"orthogonalprojection":@{@"width":@640,@"height":@360},
    @"clearenabled":@YES,@"clearcolor":@"0.2 0.2 0.2",@"cameraparallax":@NO},
    @"objects":@[@{@"id":@1,@"name":@"Known stereo spectrum GPU oracle",@"solid":@YES,
      @"size":@"160 100",@"origin":@"320 180 0",
      @"color":@{@"value":@"0 0 0",@"script":editorSpectrumSource()}}]};
  NSError* error=nil;
  NSData* data=[NSJSONSerialization dataWithJSONObject:scene options:0 error:&error];
  require(data&&[data writeToFile:[root stringByAppendingPathComponent:@"scene.json"] options:NSDataWritingAtomic error:&error],
          error.localizedDescription.UTF8String ?: "Cannot write owned stereo spectrum fixture");
}

static NSArray<NSNumber*>* editorSpectrumBands(NSInteger marker, double value) {
  NSMutableArray<NSNumber*>* bands=[NSMutableArray arrayWithCapacity:64];
  for(NSUInteger index=0;index<64;++index)[bands addObject:@0];
  if(marker>=0)bands[static_cast<NSUInteger>(marker)]=@(value);
  return bands;
}

static NSArray<NSNumber*>* editorSpectrumPattern(BOOL right) {
  NSMutableArray<NSNumber*>* bands=[NSMutableArray arrayWithCapacity:64];
  // The pinned engine applies AGC with gain >= 1 and clamps at 1. Binary
  // bands are exact fixed points, so expected values do not depend on AGC time.
  for(NSUInteger index=0;index<64;++index)[bands addObject:@((right?index%3==0:index%2==0)?1.0:0.0)];
  if(right){bands[19]=@1;bands[31]=@1;}
  else{bands[7]=@1;bands[31]=@0;}
  return bands;
}

static BOOL editorSpectrumPixels(DWWebPage* page, unsigned rgb) {
  CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;
  if(!image)return NO;
  NSData* data=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
  require(data!=nil,"Spectrum committed GPU pixel read failed");
  const auto* bytes=static_cast<const UInt8*>(data.bytes);
  const size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),rowBytes=CGImageGetBytesPerRow(image);
  require(width>=40&&height>=40&&CGImageGetBitsPerPixel(image)==32,"Spectrum GPU image has an unexpected format");
  for(size_t y=height/2-10;y<height/2+10;++y)for(size_t x=width/2-10;x<width/2+10;++x){
    const size_t at=y*rowBytes+x*4;
    // The native committed frame is BGRA. Full-intensity or zero channels avoid
    // dependence on the scene renderer's intermediate color transfer curve.
    for(unsigned channel=0;channel<3;++channel){
      const unsigned bit=1U<<(2-channel),actual=bytes[at+channel];
      if((rgb&bit)?actual<240:actual>15)return NO;
    }
  }
  return YES;
}

static NSDictionary* editorSpectrumRead(DWWebPage* page) {
  return [page previewTestValue:@"globalThis.__nativeSpectrum"];
}

static void editorSpectrumAssertBands(DWWebPage* page,NSArray<NSNumber*>* left,NSArray<NSNumber*>* right) {
  NSDictionary* actual=editorSpectrumRead(page);
  require([actual[@"noOpener"] boolValue]&&[actual[@"noAuthoring"] boolValue]&&![page scriptTestHasEditorSession],
          "Spectrum preview acquired an opener or an authoring capability");
  for(NSString* channel in @[@"left",@"right",@"average"])
    require([actual[channel] count]==64,"SceneScript spectrum channel did not have 64 bands");
  for(NSUInteger index=0;index<64;++index){
    const double l=[left[index] doubleValue],r=[right[index] doubleValue];
    require(std::abs([actual[@"left"][index] doubleValue]-l)<1e-6&&
            std::abs([actual[@"right"][index] doubleValue]-r)<1e-6&&
            std::abs([actual[@"average"][index] doubleValue]-(l+r)/2)<1e-6,
            "Actual SceneScript stereo/average bands differ from the independent native input");
  }
  require([page.audioDiagnostics[@"error"] integerValue]==0,"Spectrum preview reported a native output error");
}

static void editorSpectrumAwait(DWWebPage* page,NSArray<NSNumber*>* left,NSArray<NSNumber*>* right,unsigned rgb) {
  // Wait for the actual frame; a native setter acknowledgement alone cannot
  // prove that the scene shell fetched the data or that SceneScript used it.
  try {
    waitUntil(^{return editorSpectrumPixels(page,rgb);},4,"Known stereo spectrum did not reach actual preview GPU pixels");
  } catch(const std::exception&) {
    fprintf(stderr,"Spectrum failure actual SceneScript=%s\n",editorSpectrumRead(page).description.UTF8String);
    fprintf(stderr,"Spectrum failure native endpoint=%s\n",[[page previewTestValue:@"fetch('/__scene/spectrum').then(response=>response.json())"] description].UTF8String);
    CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;
    if(image){
      NSData* data=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
      const auto* bytes=static_cast<const UInt8*>(data.bytes);
      const size_t at=CGImageGetHeight(image)/2*CGImageGetBytesPerRow(image)+CGImageGetWidth(image)/2*4;
      fprintf(stderr,"Spectrum failure actual center BGRA=%u,%u,%u,%u expectedRGBbits=%u\n",bytes[at],bytes[at+1],bytes[at+2],bytes[at+3],rgb);
    }
    throw;
  }
  editorSpectrumAssertBands(page,left,right);
}

static void editorSpectrumDeliver(DWWebPage* page,NSArray<NSNumber*>* left,NSArray<NSNumber*>* right) {
  NSError* error=nil;
  require([page setSceneSpectrumLeft:left right:right error:&error],
          error.localizedDescription.UTF8String ?: "Native preview spectrum delivery failed");
}

static DWWebPage* editorSpectrumStart(DWWebRuntime* runtime,NSString* project,NSString* runtimeRoot,
                                    void(^failed)(NSError*)) {
  DWWebPage* page=previewCreate(runtime,project,runtimeRoot);
  __block NSError* failure=nil;
  page.onError=^(NSError* value){failure=value;failed(value);};
  page.onSceneScriptIssue=^(NSDictionary* issue){
    fprintf(stderr,"Native spectrum actual SceneScript issue: %s\n",issue.description.UTF8String);
    require(false,"Known spectrum SceneScript reported a genuine execution issue");
  };
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Spectrum preview first GPU frame timed out");
  require(!failure,failure.localizedDescription.UTF8String ?: "Spectrum preview preparation failed");
  require([[page previewTestValue:@"fetch('/__scene/config').then(response=>response.json()).then(config=>config.muted===true)"] boolValue],
          "Spectrum preview did not receive the production muted scene configuration");
  previewVerifyNativeAuthoringDenied(page);
  return page;
}

static void verifyEditorSpectrum(DWWebRuntime* runtime,NSString* sourceRoot,NSString* runtimeRoot,NSString* cache) {
  NSDictionary* sourceFiles=previewFileBytes(sourceRoot);
  NSString* project=[cache stringByAppendingPathComponent:@"OwnedStereoSpectrum"];
  NSError* error=nil;
  require([NSFileManager.defaultManager copyItemAtPath:sourceRoot toPath:project error:&error],
          error.localizedDescription.UTF8String ?: "Cannot copy self-contained spectrum fixture");
  editorSpectrumWriteFixture(project);
  NSDictionary* ownedFiles=previewFileBytes(project);
  __block NSError* failure=nil;
  DWWebPage* page=editorSpectrumStart(runtime,project,runtimeRoot,^(NSError* value){failure=value;});
  NSArray* zero=editorSpectrumBands(-1,0),*left=editorSpectrumBands(7,1),*right=editorSpectrumBands(19,1);
  editorSpectrumAwait(page,zero,zero,0);
  fprintf(stderr,"Native spectrum initial default-zero actual GPU and all 64 bands passed\n");
  editorSpectrumDeliver(page,left,zero);editorSpectrumAwait(page,left,zero,1);
  editorSpectrumDeliver(page,zero,right);editorSpectrumAwait(page,zero,right,2);
  NSArray* averageLeft=zero,*averageRight=editorSpectrumBands(31,1);
  editorSpectrumDeliver(page,averageLeft,averageRight);editorSpectrumAwait(page,averageLeft,averageRight,4);
  // Two full channels have mean 1.0, rather than the single-channel 0.5 blue oracle.
  editorSpectrumDeliver(page,averageRight,averageRight);editorSpectrumAwait(page,averageRight,averageRight,0);
  editorSpectrumDeliver(page,averageRight,zero);editorSpectrumAwait(page,averageRight,zero,4);
  editorSpectrumDeliver(page,left,right);editorSpectrumAwait(page,left,right,3);
  NSArray* patternedLeft=editorSpectrumPattern(NO),*patternedRight=editorSpectrumPattern(YES);
  editorSpectrumDeliver(page,patternedLeft,patternedRight);editorSpectrumAwait(page,patternedLeft,patternedRight,7);
  previewPlaying(page,NO);editorSpectrumDeliver(page,zero,zero);
  const double paused=[editorSpectrumRead(page)[@"runtime"] doubleValue];
  runFor(.12);
  require(std::abs([editorSpectrumRead(page)[@"runtime"] doubleValue]-paused)<1e-8,
          "Acknowledged spectrum preview pause advanced SceneScript time");
  previewPlaying(page,YES);editorSpectrumAwait(page,zero,zero,0);
  editorSpectrumDeliver(page,averageLeft,averageRight);editorSpectrumAwait(page,averageLeft,averageRight,4);
  require(!failure,failure.localizedDescription.UTF8String ?: "Spectrum preview failed");
  NSString* retiredOrigin=page.origin;
  previewClose(page,0,runtime);
  require(page.onSceneScriptIssue==nil,"Closed spectrum preview retained its native script callback");
  page=editorSpectrumStart(runtime,project,runtimeRoot,^(NSError* value){failure=value;});
  require(![page.origin isEqual:retiredOrigin],"Spectrum restart reused the retired preview origin");
  editorSpectrumAwait(page,zero,zero,0);
  editorSpectrumDeliver(page,zero,right);editorSpectrumAwait(page,zero,right,2);
  previewClose(page,0,runtime);
  require(!failure&&[previewFileBytes(project) isEqual:ownedFiles]&&[previewFileBytes(sourceRoot) isEqual:sourceFiles],
          "Spectrum preview failed or changed captured/source project bytes");
  require([NSFileManager.defaultManager removeItemAtPath:project error:&error],
          error.localizedDescription.UTF8String ?: "Closed spectrum fixture still has native file ownership");
  fprintf(stderr,"Native spectrum deterministic data path: independent L/R/mean GPU colors, pause/zero/resume fresh data, new-origin initial zero, mute, immutable files and complete page release passed (not OS capture evidence)\n");
}
