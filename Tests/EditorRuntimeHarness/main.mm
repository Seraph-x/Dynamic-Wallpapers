// Test-only access to the page's CEF instance, never a production JavaScript API.
#import "../../Sources/WebWallpaperBridge/WebPage.mm"
#include <cstdio>
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
@interface DWWebPage (EditorAcceptance)
- (void)editorTestScript:(NSString*)script;
- (void)editorTestType:(NSString*)text;
- (BOOL)editorTestNativeViewIsAttached;
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
int main(int argc,char**argv) { @autoreleasepool {
  if(argc!=6 && argc!=9){fprintf(stderr,"usage: EditorHarness FRAMEWORK HELPER CACHE RUNTIME PROJECT [MAIN_RUNTIME LOOSE_EXPORT PKG_EXPORT]\n");return 64;}
  DWWebCreateApplication(); [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; [NSApp finishLaunching];
  DWWebRuntime* runtime=[[DWWebRuntime alloc]initWithFrameworkDirectory:@(argv[1]) helperExecutable:@(argv[2]) cacheDirectory:@(argv[3])];
  NSError* error=nil;
  try {
    require([runtime startWithError:&error],error.localizedDescription.UTF8String ?: "CEF start failed");
    DWWebPage* page=nil; NSWindow* window=nil; __block NSError* failure=nil;
    @autoreleasepool {
    NSDictionary* scene=@{@"general":@{@"orthogonalprojection":@{@"width":@640,@"height":@360},@"clearenabled":@YES,@"clearcolor":@"0.1 0.1 0.1"},@"objects":@[]};
    NSDictionary* configuration=@{@"language":@"en",@"document":@{@"title":@"Native",@"entry":@"scene.json",@"scene":scene,@"project":@{@"type":@"scene",@"file":@"scene.json"}}};
    page=[runtime editorPageWithProjectRoot:@(argv[5]) runtimeRoot:@(argv[4]) configuration:configuration size:NSMakeSize(1180,760) error:&error];
    require(page!=nil,error.localizedDescription.UTF8String ?: "Editor page creation failed");
    window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1180,760) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO; page.view.frame=window.contentView.bounds;page.view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [window.contentView addSubview:page.view];[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    __block BOOL dirty=NO;
    page.onError=^(NSError* value){failure=value;};page.onEditorDirty=^(BOOL value){dirty=value;};
    [page start];waitUntil(^{return page.ready||failure!=nil;},20,"No actual Editor first-frame readiness");
    require(!failure,failure.localizedDescription.UTF8String ?: "Editor readiness failed");
    require([page editorTestNativeViewIsAttached],"CEF child view is not attached to the native editor window");
    command(page,@{@"type":@"thaw"});
    [page editorTestScript:@"document.getElementById('project-title').focus(); document.getElementById('project-title').select();"];
    runFor(.15);[page editorTestType:@"Keyboard"];
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
    @autoreleasepool { [window setContentSize:NSMakeSize(1000,650)]; } runFor(.2);
    require(page.view.bounds.size.width==1000,"Native CEF container did not resize");
    }
    __block BOOL closed=NO;[page closeWithCompletion:^(NSError* value){failure=value;closed=YES;}];
    waitUntil(^{return closed;},7,"Editor close timed out");require(!failure,"Editor close failed");
    require(runtime.activePageCount==0 && page.closed,"Editor resources remain owned after successful close");
    [window close];
    // Match AppKit's event-loop lifetime for exported playback as well as Editor setup.
    if(argc==9) for(int index=7;index<=8;++index) { @autoreleasepool {
      NSString* entry=index==7?@"scene.json":@"scene.pkg";
      DWWebPage* playback=[runtime scenePageWithProjectRoot:@(argv[index]) runtimeRoot:@(argv[6]) entry:entry
        representation:index==7?@"loose":@"package" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
      require(playback!=nil,"Exported project playback creation failed");failure=nil;playback.onError=^(NSError* value){failure=value;};
      [playback start];waitUntil(^{return playback.ready||failure!=nil;},20,"Export did not produce actual Main scene frame");
      require(!failure,failure.localizedDescription.UTF8String ?: "Exported scene failed");
      auto counts = ^NSArray* {
      CGImageRef image=(__bridge CGImageRef)playback.view.layer.contents;
      if(!image) return @[@0,@0];
      CFDataRef data=CGDataProviderCopyData(CGImageGetDataProvider(image));require(data!=nullptr,"Export pixel read failed");
      const UInt8* bytes=CFDataGetBytePtr(data);size_t green=0,red=0;
      for(CFIndex p=0;p+3<CFDataGetLength(data);p+=4){if(bytes[p+1]>180&&bytes[p]<70&&bytes[p+2]<70)++green;if(bytes[p+2]>180&&bytes[p+1]<70&&bytes[p]<70)++red;}
      CFRelease(data);return @[@(green),@(red)];
      };
      // Image/font textures can upload after the engine's first drawable frame.
      // Require actual colored pixels, not merely an engine-ready notification.
      waitUntil(^{NSArray* value=counts();return BOOL([value[0] unsignedLongValue]>100 && [value[1] unsignedLongValue]>20);},5,"Exported image/text pixels not preserved by Main scene renderer");
      fprintf(stderr,"Main export pixels green=%lu red=%lu\n",[counts()[0] unsignedLongValue],[counts()[1] unsignedLongValue]);
      __block BOOL released=NO;[playback closeWithCompletion:^(NSError* value){failure=value;released=YES;}];
      waitUntil(^{return released;},7,"Export playback close timed out");require(!failure,"Export playback close failed");
      fprintf(stderr,"Editor %s export rendered actual Main scene image/text pixels\n",index==7?"loose":"PKG");
    } }
    require([runtime shutdownWithError:&error],error.localizedDescription.UTF8String ?: "CEF shutdown failed");
    require(runtime.shutdownCount==1,"Runtime shutdown not observed");
    puts("Native Editor: real first frame, attached CEF child, keyboard, edit/undo/redo, resize and full release passed");return 0;
  } catch(const std::exception& failure) {fprintf(stderr,"Editor native acceptance failed: %s\n",failure.what());return 1;}
} }
