// Test-only access to the page's CEF instance, never a production JavaScript API.
#import "../../Sources/WebWallpaperBridge/WebPage.mm"
#include <cstdio>
#include <CommonCrypto/CommonDigest.h>
#include <stdexcept>
static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static void waitUntil(BOOL (^predicate)(), double timeout, const char* message) {
  const double deadline = NSProcessInfo.processInfo.systemUptime + timeout;
  while (!predicate()) {
    if (NSProcessInfo.processInfo.systemUptime >= deadline) throw std::runtime_error(message);
    @autoreleasepool { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]]; }
  }
}
static void runFor(double seconds) {
  double end = NSProcessInfo.processInfo.systemUptime + seconds;
  waitUntil(^{return BOOL(NSProcessInfo.processInfo.systemUptime >= end);},seconds+1,"run loop deadline");
}
// The exported model has a stationary left mesh and a right mesh driven upward
// by 0..60 px. This reads Main's committed CEF frame, not Editor preview data.
static NSArray* modelPixels(DWWebPage* page) {
  CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;
  if(!image)return @[@0,@0,@0,@0,@0,@0];
  NSData* data=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
  require(data!=nil,"Model pixel read failed");
  const auto* bytes=static_cast<const UInt8*>(data.bytes);
  const size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),rowBytes=CGImageGetBytesPerRow(image);
  size_t count[2]={0,0};double xTotal[2]={0,0},yTotal[2]={0,0};
  for(size_t y=0;y<height;++y)for(size_t x=0;x<width;++x){
    const size_t p=y*rowBytes+x*4;
    if(bytes[p+1]>180&&bytes[p]<70&&bytes[p+2]<70){const size_t half=x<width/2?0:1;++count[half];xTotal[half]+=x;yTotal[half]+=y;}
  }
  return @[@(count[0]),@(count[1]),@(count[0]?xTotal[0]/count[0]:0),@(count[1]?xTotal[1]/count[1]:0),
           @(count[0]?yTotal[0]/count[0]:0),@(count[1]?yTotal[1]/count[1]:0)];
}
static void verifyModelExport(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,BOOL package,double bindShift=0) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json"
    representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Model playback creation failed");
  page.onError=^(NSError* value){failure=value;};[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Main model first frame timed out");require(!failure,"Main model playback failed");
  waitUntil(^{NSArray* p=modelPixels(page);return BOOL([p[0] unsignedLongValue]>100&&[p[1] unsignedLongValue]>100);},5,"Main did not render both skinned model meshes");
  __block double low=1e9,high=-1e9;
  waitUntil(^{
    NSArray* p=modelPixels(page);
    if([p[0] unsignedLongValue]<=100||[p[1] unsignedLongValue]<=100)return NO;
    require(std::abs([p[2] doubleValue]-284.5)<3&&std::abs([p[3] doubleValue]-(354.5-bindShift))<3,"Model joint reindex changed horizontal bind placement");
    require(std::abs([p[4] doubleValue]-179.5)<3,"Stationary model bone moved in Main");
    const double delta=[p[4] doubleValue]-[p[5] doubleValue];
    require(delta>=-2&&delta<=62,"Model deformation left the known 0..60 pixel range");
    low=std::min(low,delta);high=std::max(high,delta);
    return BOOL(delta>15&&delta<45&&high-low>10);
  },3,"Main did not render known intermediate skeletal deformation");
  require(!failure,"Main model rendering reported an error");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];
  waitUntil(^{return released;},7,"Model playback close timed out");require(!failure,"Model playback close failed");
  fprintf(stderr,"Main %s model export: stationary bind and intermediate skin deformation %.2f..%.2f px passed\n",package?"PKG":"loose",low,high);
}
@interface DWWebPage (EditorAcceptance)
- (void)editorTestScript:(NSString*)script;
- (void)editorTestType:(NSString*)text;
- (BOOL)editorTestNativeViewIsAttached;
- (void)editorTestAwaitTitle:(NSString*)expected;
- (void)editorTestAwaitInput:(NSString*)selector value:(NSString*)expected;
- (void)editorTestAwaitInput:(NSString*)selector value:(NSString*)expected focused:(BOOL)focused;
@end
@implementation DWWebPage (EditorAcceptance)
- (void)editorTestScript:(NSString*)script {
  _resources->state->browser->GetMainFrame()->ExecuteJavaScript(script.UTF8String,"https://"+_resources->state->host+"/__runtime/index.html",0);
}
- (void)editorTestType:(NSString*)text {
  @autoreleasepool {
  _resources->state->browser->GetHost()->SetFocus(true);
  NSView* child=(__bridge NSView*)_resources->state->browser->GetHost()->GetWindowHandle();
  for (NSUInteger index=0; index<text.length; ++index) {
    NSString* character=[text substringWithRange:NSMakeRange(index,1)];
    NSEvent* event=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
      timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:child.window.windowNumber context:nil
      characters:character charactersIgnoringModifiers:character isARepeat:NO keyCode:0];
    [NSApp sendEvent:event];
  }
  }
}
- (void)editorTestAwaitTitle:(NSString*)expected {
  [self editorTestAwaitInput:@"#project-title" value:expected];
}
- (void)editorTestAwaitInput:(NSString*)selector value:(NSString*)expected {
  [self editorTestAwaitInput:selector value:expected focused:NO];
}
- (void)editorTestAwaitInput:(NSString*)selector value:(NSString*)expected focused:(BOOL)focused {
  __block BOOL done=NO; __block NSError* failure=nil; NSString* identifier=NSUUID.UUID.UUIDString;
  _editorCompletions[identifier]=^(NSDictionary* reply,NSError* error){failure=error;done=[reply[@"typed"] boolValue]||error!=nil;};
  _editorDeadlines[identifier]=@(NSProcessInfo.processInfo.systemUptime+5);
  NSDictionary* value=@{@"selector":selector,@"expected":expected,@"focused":@(focused),@"payload":@{@"type":@"reply",@"id":identifier,@"session":@(_resources->state->editor->session.c_str()),@"generation":@1,@"payload":@{@"typed":@YES}}};
  NSString* json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:value options:0 error:nil] encoding:NSUTF8StringEncoding];
  [self editorTestScript:[NSString stringWithFormat:@"(()=>{const test=%@;const check=()=>{if(document.querySelector(test.selector).value===test.expected&&(!test.focused||document.activeElement===document.querySelector(test.selector)))fetch('/__editor/event',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(test.payload)});else requestAnimationFrame(check);};check();})();",json]];
  waitUntil(^{return done;},6,"Native keyboard input did not reach the renderer before blur"); require(!failure,"Keyboard input acknowledgement failed");
}
- (BOOL)editorTestNativeViewIsAttached {
  NSView* child=(__bridge NSView*)_resources->state->browser->GetHost()->GetWindowHandle();
  return child && child.superview == _view && child.window == _view.window;
}
@end
static NSDictionary* command(DWWebPage* page, NSDictionary* payload) {
  __block BOOL done=NO; __block NSDictionary* reply=nil; __block NSError* failure=nil;
  [page requestEditorCommand:payload completion:^(NSDictionary* value,NSError* error){reply=value;failure=error;done=YES;}];
  waitUntil(^{return done;},35,"Editor command reply timeout");
  require(!failure,failure.localizedDescription.UTF8String ?: "Editor command failed");
  require(reply && !reply[@"error"], [reply[@"error"] UTF8String] ?: "Editor returned no reply");return reply;
}
static NSString* resourceHash(NSData* data) {
  unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,static_cast<CC_LONG>(data.length),hash);
  NSMutableString* result=[NSMutableString string]; for(auto byte:hash)[result appendFormat:@"%02x",byte];return result;
}
static NSMutableDictionary* configureResources(DWWebPage* page, NSString* root, NSString* projectRoot, void (^onFailure)(NSError*)) {
  NSError* error=nil;require([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&error],"Cannot create native resource test store");
  NSMutableDictionary* stats=[@{@"beforeReady":@0} mutableCopy]; __weak DWWebPage* weakPage=page;
  page.onEditorResource=^(NSDictionary<NSString*,id>* request){
    DWWebPage* current=weakPage; require(current!=nil,"Resource request lost its page");
    NSError* error=nil;NSDictionary* result;
    if([request[@"action"] isEqual:@"list"]) {
      NSMutableArray* paths=[NSMutableArray array];
      NSDirectoryEnumerator* enumerator=[NSFileManager.defaultManager enumeratorAtPath:projectRoot];
      for(NSString* path in enumerator){BOOL directory=NO;
        if([NSFileManager.defaultManager fileExistsAtPath:[projectRoot stringByAppendingPathComponent:path] isDirectory:&directory]&&!directory)[paths addObject:path];}
      result=@{@"paths":paths};
    } else if([request[@"action"] isEqual:@"stage"]) {
      NSData* bytes=[[NSData alloc]initWithBase64EncodedString:request[@"data"] options:0];require(bytes!=nil,"Invalid test resource bytes");
      NSString* version=resourceHash(bytes);BOOL written=[bytes writeToFile:[root stringByAppendingPathComponent:version] options:NSDataWritingAtomic error:&error];
      result=written?@{@"version":version}:@{@"error":error.localizedDescription};
    } else {
      if(!current.ready) stats[@"beforeReady"]=@([stats[@"beforeReady"] unsignedIntegerValue]+1);
      NSData* bytes=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:request[@"version"]] options:0 error:&error];
      if(bytes && [resourceHash(bytes) isEqual:request[@"version"]]) result=@{@"data":[bytes base64EncodedStringWithOptions:0]};
      else result=@{@"error":error.localizedDescription ?: @"Corrupt test resource"};
    }
    [current requestEditorCommand:@{@"type":@"resource-reply",@"requestID":request[@"id"],@"result":result} completion:^(NSDictionary* reply,NSError* failure){
      if(failure) onFailure(failure); else if(reply[@"error"]) onFailure([NSError errorWithDomain:@"EditorAcceptance" code:1 userInfo:@{NSLocalizedDescriptionKey:reply[@"error"]}]);
    }];
  };return stats;
}
static void verifyModelWorkbench(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,NSString* resources) {
  NSData* sceneData=[NSData dataWithContentsOfFile:[projectRoot stringByAppendingPathComponent:@"scene.json"]];
  NSData* projectData=[NSData dataWithContentsOfFile:[projectRoot stringByAppendingPathComponent:@"project.json"]];
  require(sceneData!=nil&&projectData!=nil,"Native model source fixture missing");
  NSDictionary* scene=[NSJSONSerialization JSONObjectWithData:sceneData options:0 error:nil];
  NSDictionary* project=[NSJSONSerialization JSONObjectWithData:projectData options:0 error:nil];
  NSDictionary* config=@{@"language":@"en",@"document":@{@"title":@"Native model",@"entry":@"scene.json",@"scene":scene,@"project":project}};
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:config size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native Model workbench creation failed");
  page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});
  NSWindow* window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1180,760) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;page.view.frame=window.contentView.bounds;[window.contentView addSubview:page.view];[window makeKeyAndOrderFront:nil];
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native Model workbench first frame timed out");require(!failure,"Native Model workbench failed");
  command(page,@{@"type":@"thaw"});[page editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"1\"]').click();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"document.getElementById('model-workspace').click();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"document.querySelector('#model-bones button[data-bone=\"1\"]').click();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"document.getElementById('model-bone-name').focus();document.getElementById('model-bone-name').select();"];
  runFor(.1);[page editorTestType:@"Native Wing"];[page editorTestAwaitInput:@"#model-bone-name" value:@"Native Wing"];
  NSDictionary* frozen=command(page,@{@"type":@"freeze"}),*document=frozen[@"document"];
  NSString* path=@"models/editor/rig.mdl",*version=document[@"resourceOverrides"][path];
  require(version.length==64&&[frozen[@"dirty"] boolValue],"Unblurred native model input was not committed before freeze");
  NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:version]];
  require(bytes!=nil&&[[resourceHash(bytes) lowercaseString] isEqual:version],"Native model resource hash mismatch");
  NSData* name=[@"Native Wing" dataUsingEncoding:NSUTF8StringEncoding];require([bytes rangeOfData:name options:0 range:NSMakeRange(0,bytes.length)].location!=NSNotFound,"Native model resource did not contain the typed bone name");
  command(page,@{@"type":@"mark-saved",@"document":document});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native model saved acknowledgement remained dirty");
  command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});
  require(command(page,@{@"type":@"snapshot"})[@"document"][@"resourceOverrides"][path]==nil,"Native model undo did not restore the original resource");
  command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"][@"resourceOverrides"][path] isEqual:version],"Native model redo did not restore the authored resource");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native model editor close timed out");require(!failure,"Native model editor close failed");[window close];
  fprintf(stderr,"Native Model workspace: actual keyboard, unblurred freeze, staged MDL name/hash, save acknowledgement and undo/redo passed\n");
}
#include "ImagePuppetAcceptance.h"
#include "RestAcceptance.h"
#include "GltfAcceptance.h"
int main(int argc,char**argv) { @autoreleasepool {
  const bool brushOnly=argc>1&&std::string(argv[1])=="--brush-only",restOnly=argc>1&&std::string(argv[1])=="--rest-only",gltfOnly=argc>1&&std::string(argv[1])=="--gltf-only";if(brushOnly||restOnly||gltfOnly){++argv;--argc;}
  if(gltfOnly?argc!=10:argc!=6 && argc!=9 && argc!=11 && argc!=14 && argc!=16){fprintf(stderr,"usage: EditorHarness FRAMEWORK HELPER CACHE RUNTIME PROJECT [MAIN_RUNTIME LOOSE_EXPORT PKG_EXPORT [MODEL_LOOSE MODEL_PKG [IMAGE_SOURCE IMAGE_LOOSE IMAGE_PKG [BRUSH_LOOSE BRUSH_PKG]]]]\n       EditorHarness --gltf-only FRAMEWORK HELPER CACHE RUNTIME SOURCE_PROJECT MAIN_RUNTIME GLTF_LOOSE GLTF_PKG SOURCE_COMMAND\n");return 64;}
  DWWebCreateApplication(); [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; [NSApp finishLaunching];
  DWWebRuntime* runtime=[[DWWebRuntime alloc]initWithFrameworkDirectory:@(argv[1]) helperExecutable:@(argv[2]) cacheDirectory:@(argv[3])];
  NSError* error=nil;
  try {
    require([runtime startWithError:&error],error.localizedDescription.UTF8String ?: "CEF start failed");
    if(gltfOnly){
      @autoreleasepool{
        verifyGltfWorkbench(runtime,@(argv[5]),@(argv[4]),[@(argv[3]) stringByAppendingPathComponent:@"GltfResources"],@(argv[9]));
        verifyGltfExport(runtime,@(argv[7]),@(argv[6]),NO);
        verifyGltfExport(runtime,@(argv[8]),@(argv[6]),YES);
      }
      require([runtime shutdownWithError:&error],error.localizedDescription.UTF8String ?: "glTF CEF shutdown failed");
      require(runtime.shutdownCount==1,"glTF runtime shutdown was not exactly once");puts("Native glTF: actual import, trusted keyboard, atomic history, source archive, both Main exports and full release passed");return 0;
    }
    if(restOnly){
      require(argc==9,"Rest acceptance requires source and both authored exports");
      @autoreleasepool{
        verifyRestWorkbench(runtime,@(argv[5]),@(argv[4]),[@(argv[3]) stringByAppendingPathComponent:@"RestResources"]);
        verifyModelExport(runtime,@(argv[7]),@(argv[6]),NO,10);
        verifyModelExport(runtime,@(argv[8]),@(argv[6]),YES,10);
      }
      require([runtime shutdownWithError:&error],error.localizedDescription.UTF8String ?: "Rest CEF shutdown failed");
      require(runtime.shutdownCount==1,"Rest runtime shutdown not observed");puts("Native rest: actual keyboard, bind history, shifted animated exports and full release passed");return 0;
    }
    if(brushOnly){
      require(argc==16,"Brush acceptance requires image source and both brush exports");
      @autoreleasepool{
        verifyImageCreation(runtime,@(argv[11]),@(argv[4]),[@(argv[3]) stringByAppendingPathComponent:@"BrushResources"],YES);
        verifyImageExport(runtime,@(argv[14]),@(argv[6]),NO,YES,YES);
        verifyImageExport(runtime,@(argv[15]),@(argv[6]),YES,YES,YES);
      }
      require([runtime shutdownWithError:&error],error.localizedDescription.UTF8String ?: "Brush CEF shutdown failed");
      require(runtime.shutdownCount==1,"Brush runtime shutdown not observed");puts("Native brush: actual CEF pointer, resource history, painted exports and full release passed");return 0;
    }
    DWWebPage* page=nil; NSWindow* window=nil; __block NSError* failure=nil; NSDictionary* resourceSnapshot=nil;
    NSString* resourceRoot=[@(argv[3]) stringByAppendingPathComponent:@"NativeResources"];
    @autoreleasepool {
    NSDictionary* scene=@{@"general":@{@"orthogonalprojection":@{@"width":@640,@"height":@360},@"clearenabled":@YES,@"clearcolor":@"0.1 0.1 0.1"},@"objects":@[]};
    NSDictionary* configuration=@{@"language":@"en",@"document":@{@"title":@"Native",@"entry":@"scene.json",@"scene":scene,@"project":@{@"type":@"scene",@"file":@"scene.json"}}};
    page=[runtime editorPageWithProjectRoot:@(argc>=9?argv[7]:argv[5]) runtimeRoot:@(argv[4]) configuration:configuration size:NSMakeSize(1180,760) error:&error];
    require(page!=nil,error.localizedDescription.UTF8String ?: "Editor page creation failed");
    window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1180,760) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO; page.view.frame=window.contentView.bounds;page.view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [window.contentView addSubview:page.view];[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    __block BOOL dirty=NO;
    page.onError=^(NSError* value){failure=value;};page.onEditorDirty=^(BOOL value){dirty=value;};
    configureResources(page,resourceRoot,@(argc>=9?argv[7]:argv[5]),^(NSError* value){failure=value;});
    [page start];waitUntil(^{return page.ready||failure!=nil;},20,"No actual Editor first-frame readiness");
    require(!failure,failure.localizedDescription.UTF8String ?: "Editor readiness failed");
    require([page editorTestNativeViewIsAttached],"CEF child view is not attached to the native editor window");
    command(page,@{@"type":@"thaw"});
    [page editorTestScript:@"document.getElementById('project-title').focus(); document.getElementById('project-title').select();"];
    runFor(.15);[page editorTestType:@"Keyboard"];[page editorTestAwaitTitle:@"Keyboard"];
    [page editorTestScript:@"document.getElementById('project-title').blur(); document.getElementById('add-text').click();"];
    runFor(.5);
    NSDictionary* snapshot=command(page,@{@"type":@"snapshot"})[@"document"];
    fprintf(stderr,"Native keyboard snapshot title=%s\n",[snapshot[@"title"] UTF8String]);
    require([snapshot[@"title"] isEqual:@"Keyboard"],"Real CEF keyboard input did not update the project title");
    require([snapshot[@"scene"][@"objects"] count]==1 && dirty,"Actual text-layer UI action did not produce a dirty scene");
    command(page,@{@"type":@"mark-saved",@"document":snapshot});
    require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native JSON save acknowledgement incorrectly remained dirty");
    command(page,@{@"type":@"thaw"});
    command(page,@{@"type":@"undo"});
    require([command(page,@{@"type":@"snapshot"})[@"document"][@"scene"][@"objects"] count]==0,"Native undo did not change scene document");
    command(page,@{@"type":@"redo"});
    [page editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"1\"]').click();document.getElementById('timeline-toggle').click();"];
    command(page,@{@"type":@"snapshot"});
    [page editorTestScript:@"document.getElementById('timeline-create').click();"];
    NSDictionary* animated=command(page,@{@"type":@"snapshot"})[@"document"];
    require([animated[@"scene"][@"objects"][0][@"origin"][@"animation"][@"c0"] count]==1,"Native CEF timeline did not create a property track");
    [page editorTestScript:@"const field=document.getElementById('timeline-key-value');field.value='360';field.dispatchEvent(new Event('input',{bubbles:true}));"];
    NSDictionary* timelineSaved=command(page,@{@"type":@"freeze"})[@"document"];
    require([timelineSaved[@"scene"][@"objects"][0][@"origin"][@"animation"][@"c0"][0][@"value"] doubleValue]==360,"Native freeze lost pending timeline input");
    command(page,@{@"type":@"mark-saved",@"document":timelineSaved});
    require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native timeline save acknowledgement remained dirty");
    command(page,@{@"type":@"thaw"});
    require(std::abs([command(page,@{@"type":@"seek",@"time":@.5})[@"time"] doubleValue]-.5)<1e-8,"Native timeline seek did not reach the requested time");
    fprintf(stderr,"Native CEF timeline create, unblurred draft freeze, saved acknowledgement and typed seek passed\n");
    if(argc>=9) {
      NSData* model=[NSData dataWithContentsOfFile:[@(argv[7]) stringByAppendingPathComponent:@"models/editor/green.json"]]; require(model!=nil,"Resource model fixture missing");
      command(page,@{@"type":@"replace-resource",@"path":@"models/editor/green.json",@"data":[model base64EncodedStringWithOptions:0]});
      command(page,@{@"type":@"add-image",@"image":@{@"name":@"Resource image",@"model":@"models/editor/green.json",@"width":@80,@"height":@40}});
      resourceSnapshot=command(page,@{@"type":@"freeze"})[@"document"];
      require([resourceSnapshot[@"resourceOverrides"] count]==1,"Native resource transaction was not committed");
      command(page,@{@"type":@"mark-saved",@"document":resourceSnapshot});
      require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Resource save acknowledgement remained dirty");
    }
    @autoreleasepool { [window setContentSize:NSMakeSize(1000,650)]; } runFor(.2);
    require(page.view.bounds.size.width==1000,"Native CEF container did not resize");
    }
    __block BOOL closed=NO;[page closeWithCompletion:^(NSError* value){failure=value;closed=YES;}];
    waitUntil(^{return closed;},7,"Editor close timed out");require(!failure,"Editor close failed");
    require(runtime.activePageCount==0 && page.closed,"Editor resources remain owned after successful close");
    [window close];
    if(resourceSnapshot) { @autoreleasepool {
      DWWebPage* reopened=[runtime editorPageWithProjectRoot:@(argv[7]) runtimeRoot:@(argv[4]) configuration:@{@"language":@"en",@"document":resourceSnapshot} size:NSMakeSize(640,360) error:&error];
      require(reopened!=nil,"Cannot reopen resource revision"); failure=nil;
      reopened.onError=^(NSError* value){failure=value;};
      NSMutableDictionary* stats=configureResources(reopened,resourceRoot,@(argv[7]),^(NSError* value){failure=value;});
      NSWindow* host=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,640,360) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];host.releasedWhenClosed=NO;
      [host.contentView addSubview:reopened.view];[host makeKeyAndOrderFront:nil];
      [reopened start];waitUntil(^{return reopened.ready||failure!=nil;},20,"Resource reopen initial rendering deadlocked");
      require(!failure,"Resource reopen failed");require([stats[@"beforeReady"] unsignedIntegerValue]>0,"Initial rendering did not exercise pre-ready resource RPC");
      __block BOOL released=NO;[reopened closeWithCompletion:^(NSError* value){failure=value;released=YES;}];
      waitUntil(^{return released;},7,"Resource reopen close timed out");require(!failure,"Resource reopen close failed");[host close];
      fprintf(stderr,"Native resource stage/read, save acknowledgement and pre-ready reopen passed\n");
    } }
    // Match AppKit's event-loop lifetime for exported playback as well as Editor setup.
    if(argc>=9) for(int index=7;index<=8;++index) { @autoreleasepool {
      NSString* entry=index==7?@"scene.json":@"scene.pkg";
      DWWebPage* playback=[runtime scenePageWithProjectRoot:@(argv[index]) runtimeRoot:@(argv[6]) entry:entry
        representation:index==7?@"loose":@"package" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
      require(playback!=nil,"Exported project playback creation failed");failure=nil;playback.onError=^(NSError* value){failure=value;};
      [playback start];waitUntil(^{return playback.ready||failure!=nil;},20,"Export did not produce actual Main scene frame");
      require(!failure,failure.localizedDescription.UTF8String ?: "Exported scene failed");
      auto counts = ^NSArray* {
      CGImageRef image=(__bridge CGImageRef)playback.view.layer.contents;
      if(!image) return @[@0,@0,@0,@0];
      CFDataRef data=CGDataProviderCopyData(CGImageGetDataProvider(image));require(data!=nullptr,"Export pixel read failed");
      const UInt8* bytes=CFDataGetBytePtr(data);size_t green=0,red=0,blue=0;double greenX=0;const size_t rowBytes=CGImageGetBytesPerRow(image);
      for(CFIndex p=0;p+3<CFDataGetLength(data);p+=4){if(bytes[p+1]>180&&bytes[p]<70&&bytes[p+2]<70){++green;greenX+=double((static_cast<size_t>(p)%rowBytes)/4);}if(bytes[p+2]>180&&bytes[p+1]<70&&bytes[p]<70)++red;if(bytes[p]>180&&bytes[p+1]<70&&bytes[p+2]<70)++blue;}
      CFRelease(data);return @[@(green),@(red),@(blue),@(green?greenX/green:0)];
      };
      // Image/font textures can upload after the engine's first drawable frame.
      // Require actual colored pixels, not merely an engine-ready notification.
      waitUntil(^{NSArray* value=counts();return BOOL([value[0] unsignedLongValue]>100 && [value[1] unsignedLongValue]>20 && [value[2] unsignedLongValue]>100);},5,"Exported image/text pixels not preserved by Main scene renderer");
      fprintf(stderr,"Main export pixels green=%lu red=%lu blue=%lu\n",[counts()[0] unsignedLongValue],[counts()[1] unsignedLongValue],[counts()[2] unsignedLongValue]);
      const double firstX=[counts()[3] doubleValue];
      waitUntil(^{return BOOL(std::abs([counts()[3] doubleValue]-firstX)>3);},3,"Exported property keyframes did not animate in Main");
      fprintf(stderr,"Main export animation centroid %.2f -> %.2f\n",firstX,[counts()[3] doubleValue]);
      __block BOOL released=NO;[playback closeWithCompletion:^(NSError* value){failure=value;released=YES;}];
      waitUntil(^{return released;},7,"Export playback close timed out");require(!failure,"Export playback close failed");
      fprintf(stderr,"Editor %s export rendered actual Main scene image/text pixels\n",index==7?"loose":"PKG");
    } }
    if(argc>=11)for(int index=9;index<=10;++index){@autoreleasepool{verifyModelExport(runtime,@(argv[index]),@(argv[6]),index==10);}}
    if(argc>=11){@autoreleasepool{verifyModelWorkbench(runtime,@(argv[9]),@(argv[4]),[@(argv[3]) stringByAppendingPathComponent:@"ModelResources"]);}}
    if(argc>=14){@autoreleasepool{
      verifyImageCreation(runtime,@(argv[11]),@(argv[4]),[@(argv[3]) stringByAppendingPathComponent:@"ImageResources"]);
      verifyImageExport(runtime,@(argv[11]),@(argv[6]),NO,NO);
      verifyImageExport(runtime,@(argv[12]),@(argv[6]),NO,YES);
      verifyImageExport(runtime,@(argv[13]),@(argv[6]),YES,YES);
    }}
    if(argc==16){@autoreleasepool{
      verifyImageExport(runtime,@(argv[14]),@(argv[6]),NO,YES,YES);
      verifyImageExport(runtime,@(argv[15]),@(argv[6]),YES,YES,YES);
    }}
    require([runtime shutdownWithError:&error],error.localizedDescription.UTF8String ?: "CEF shutdown failed");
    require(runtime.shutdownCount==1,"Runtime shutdown not observed");
    puts("Native Editor: real first frame, attached CEF child, keyboard, edit/undo/redo, resize and full release passed");return 0;
  } catch(const std::exception& failure) {fprintf(stderr,"Editor native acceptance failed: %s\n",failure.what());return 1;}
} }
