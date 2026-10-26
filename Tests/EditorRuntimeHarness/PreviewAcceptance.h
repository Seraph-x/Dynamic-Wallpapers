#pragma once
#include "include/cef_devtools_message_observer.h"
#include "include/cef_task.h"

// Read real renderer state through CEF's native debugging transport. Scene pages
// intentionally have no Editor reply endpoint; this adds no production API.
class PreviewDevToolsResult final : public CefDevToolsMessageObserver {
 public:
  bool done = false;
  bool succeeded = false;
  bool submitted = false;
  int submittedID = 0;
  int receivedID = 0;
  std::string bytes;
  void OnDevToolsAgentAttached(CefRefPtr<CefBrowser>) override {
    fprintf(stderr,"Native preview DevTools agent attached cefUI=%d\n",int(CefCurrentlyOn(TID_UI)));
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int identifier, bool success,
                             const void* result, size_t length) override {
    receivedID = identifier;
    succeeded = success;
    if (length) bytes.assign(static_cast<const char*>(result), length);
    done = true;
  }
 private:
  IMPLEMENT_REFCOUNTING(PreviewDevToolsResult);
};

class PreviewDevToolsQuery final : public CefTask {
 public:
  CefRefPtr<CefRegistration> registration;
  PreviewDevToolsQuery(CefRefPtr<CefBrowserHost> host, CefRefPtr<CefDictionaryValue> parameters,
                      CefRefPtr<PreviewDevToolsResult> result)
      : host_(host), parameters_(parameters), result_(result) {}
  void Execute() override {
    // AppKit's main run loop can be outside CEF's logical UI task context even
    // with the external message pump. ExecuteDevToolsMethod then posts itself
    // and returns 0, losing the assigned ID. Register and submit on TID_UI.
    registration = host_->AddDevToolsMessageObserver(result_);
    if (registration)
      result_->submittedID = host_->ExecuteDevToolsMethod(0,"Runtime.evaluate",parameters_);
    fprintf(stderr,"Native preview DevTools query submittedID=%d cefUI=%d registered=%d\n",
            result_->submittedID,int(CefCurrentlyOn(TID_UI)),int(bool(registration)));
    result_->submitted = true;
  }
 private:
  const CefRefPtr<CefBrowserHost> host_;
  const CefRefPtr<CefDictionaryValue> parameters_;
  const CefRefPtr<PreviewDevToolsResult> result_;
  IMPLEMENT_REFCOUNTING(PreviewDevToolsQuery);
};

@interface DWWebPage (PreviewAcceptance)
- (id)previewTestValue:(NSString*)expression;
- (NSString*)previewTestEditorSession;
@end
@implementation DWWebPage (PreviewAcceptance)
- (id)previewTestValue:(NSString*)expression {
  CefRefPtr<PreviewDevToolsResult> observer = new PreviewDevToolsResult;
  auto host = _resources->state->browser->GetHost();
  auto parameters = CefDictionaryValue::Create();
  parameters->SetString("expression", expression.UTF8String);
  parameters->SetBool("returnByValue", true);
  parameters->SetBool("awaitPromise", true);
  CefRefPtr<PreviewDevToolsQuery> query = new PreviewDevToolsQuery(host,parameters,observer);
  fprintf(stderr,"Native preview DevTools query dispatch callerCefUI=%d\n",int(CefCurrentlyOn(TID_UI)));
  require(CefPostTask(TID_UI,query),"Preview renderer query could not be scheduled on CEF UI");
  waitUntil(^{return BOOL(observer->submitted);},6,"Preview renderer query submission timed out");
  require(query->registration && observer->submittedID>0,"Preview renderer query was not submitted");
  waitUntil(^{return BOOL(observer->done);},6,"Preview renderer query timed out");
  require(observer->receivedID==observer->submittedID,"Preview renderer query returned an unrelated message ID");
  require(observer->succeeded,"Preview renderer query transport failed");
  NSData* bytes = [NSData dataWithBytes:observer->bytes.data() length:observer->bytes.size()];
  NSDictionary* reply = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  require(reply && !reply[@"exceptionDetails"], "Preview renderer query threw an exception");
  id value = reply[@"result"][@"value"];
  require(value != nil,"Preview renderer query returned no serializable value");
  return value;
}
- (NSString*)previewTestEditorSession { return @(_resources->state->editor->session.c_str()); }
@end

static NSDictionary* previewFileBytes(NSString* root) {
  NSMutableDictionary* result = [NSMutableDictionary dictionary];
  NSDirectoryEnumerator* paths = [NSFileManager.defaultManager enumeratorAtPath:root];
  require(paths != nil,"Preview project enumeration failed");
  for (NSString* relative in paths) {
    NSString* path = [root stringByAppendingPathComponent:relative];
    BOOL directory = NO;
    require([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory],"Preview project resource disappeared");
    if (directory) continue;
    NSData* bytes = [NSData dataWithContentsOfFile:path];
    require(bytes != nil,"Preview project resource could not be read");
    result[relative] = bytes;
  }
  require(result.count > 0,"Preview fixture is empty");
  return result;
}

static void previewWriteScript(NSString* root, NSString* source) {
  NSMutableDictionary* scene = [clipJSON([root stringByAppendingPathComponent:@"scene.json"]) mutableCopy];
  NSMutableArray* objects = [scene[@"objects"] mutableCopy];
  require(objects.count == 1,"Preview fixture requires one actual model layer");
  NSMutableDictionary* layer = [objects[0] mutableCopy], *color = [layer[@"color"] mutableCopy];
  require([color[@"script"] isEqual:scriptContractWave()],"Preview source fixture does not contain the known half-second color wave");
  color[@"script"] = source; layer[@"color"] = color; objects[0] = layer; scene[@"objects"] = objects;
  NSError* error = nil;
  NSData* bytes = [NSJSONSerialization dataWithJSONObject:scene options:0 error:&error];
  require(bytes && [bytes writeToFile:[root stringByAppendingPathComponent:@"scene.json"] options:NSDataWritingAtomic error:&error],
          error.localizedDescription.UTF8String ?: "Cannot write owned preview script fixture");
}

static void previewClose(DWWebPage* page, NSUInteger remaining, DWWebRuntime* runtime) {
  __block BOOL done = NO; __block NSError* failure = nil;
  [page closeWithCompletion:^(NSError* error){failure=error;done=YES;}];
  waitUntil(^{return done;},7,"Preview page release timed out");
  require(!failure && page.closed && runtime.activePageCount==remaining,"Preview page was not actually released");
}

static DWWebPage* previewCreate(DWWebRuntime* runtime, NSString* root, NSString* runtimeRoot) {
  NSError* error = nil;
  DWWebPage* page = [runtime scenePageWithProjectRoot:root runtimeRoot:runtimeRoot entry:@"scene.json"
    representation:@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page != nil,error.localizedDescription.UTF8String ?: "Preview scene page creation failed");
  require(![page scriptTestHasEditorSession],"Preview acquired an authoring session");
  require([page setOutputGain:0 error:&error],error.localizedDescription.UTF8String ?: "Cannot mute preview output before start");
  return page;
}

static void previewPlaying(DWWebPage* page, BOOL playing) {
  __block BOOL done = NO; __block NSError* failure = nil;
  [page setScenePlaying:playing completion:^(NSError* error){failure=error;done=YES;}];
  waitUntil(^{return done;},6,"Preview playback command acknowledgement timed out");
  require(!failure,failure.localizedDescription.UTF8String ?: "Preview playback acknowledgement failed");
}

static BOOL previewColor(DWWebPage* page, NSString* color) {
  NSDictionary* pixels = eventPixels(page);
  return [pixels[color][0] unsignedLongValue]>100 && [pixels[color][1] unsignedLongValue]>100;
}

static NSString* previewProbeSource(DWWebPage* editor, BOOL attack) {
  NSDictionary* target = @{@"origin":editor.origin,@"session":[editor previewTestEditorSession],@"attack":@(attack)};
  NSString* json = [[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:target options:0 error:nil] encoding:NSUTF8StringEncoding];
  NSString* source = [NSString stringWithUTF8String:R"JS(
const host=({}).constructor.constructor('return globalThis')();
const target=__TARGET__;
export function init(value){
  const probe=host.__previewProbe={done:false,firstRuntime:null,runtime:0,
    noOpener:host.opener===null,
    noAuthoring:!['__dynamicWallpaperEditor','__editor','__editorConfiguration','__editorSession'].some(key=>key in host)};
  if(!target.attack){probe.done=true;return value;}
  (async()=>{
    const event={type:'resource',id:'preview-must-not-stage',session:target.session,generation:1,action:'stage',data:'cHJldmlldy1tdXN0LW5vdC1zdGFnZQ=='};
    const options={method:'POST',headers:{'Content-Type':'application/json'},body:host.JSON.stringify(event)};
    const denied=async(url,init)=>{try{const response=await host.fetch(url,init);return {denied:!response.ok,status:response.status};}catch(error){return {denied:true,error:String(error)};}};
    probe.results=await host.Promise.all([
      denied('/__editor/config'),denied('/__editor/event',options),denied('/__editor/resource',options),
      denied('/__project/scene.json',{method:'POST',body:'must-not-write'}),
      denied(target.origin+'/__editor/config'),denied(target.origin+'/__editor/event',options),denied(target.origin+'/__editor/resource',options)
    ]);
    probe.done=true;
  })().catch(error=>{probe.error=String(error);probe.done=true;});
  return value;
}
export function update(value){
  const probe=host.__previewProbe;probe.runtime=engine.runtime;
  if(probe.firstRuntime===null)probe.firstRuntime=engine.runtime;
  const audio=engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_64);
  probe.zeroSpectrum=audio.left.length===64&&audio.right.length===64&&audio.left.every(value=>value===0)&&audio.right.every(value=>value===0);
  return Math.floor(engine.runtime*2)%2===0?{x:0,y:1,z:0}:{x:1,y:0,z:0};
}
)JS"];
  return [source stringByReplacingOccurrencesOfString:@"__TARGET__" withString:json];
}

static void previewVerifyProbe(DWWebPage* page) {
  NSDictionary* probe = [page previewTestValue:@"new Promise(resolve=>{const poll=()=>globalThis.__previewProbe?.done?resolve(globalThis.__previewProbe):setTimeout(poll,5);poll();})"];
  require(!probe[@"error"] && [probe[@"noOpener"] boolValue] && [probe[@"noAuthoring"] boolValue],"Actual preview script found an opener/authoring global or failed its probes");
  require([probe[@"results"] count]==7,"Actual preview script did not run every boundary request");
  for (NSDictionary* result in probe[@"results"])
    require([result[@"denied"] boolValue],"Actual preview script reached an authoring or project-write endpoint");
}

static void previewVerifyNativeAuthoringDenied(DWWebPage* page) {
  __block BOOL done=NO; __block NSDictionary* reply=nil; __block NSError* failure=nil;
  [page requestEditorCommand:@{@"type":@"snapshot"} completion:^(NSDictionary* value,NSError* error){reply=value;failure=error;done=YES;}];
  waitUntil(^{return done;},2,"Preview authoring command rejection timed out");
  require(failure && !reply && ![page scriptTestHasEditorSession],"Preview accepted a native Editor command or acquired a session");
}

static void previewVerifyInitialClock(DWWebPage* page) {
  NSDictionary* probe=[page previewTestValue:@"globalThis.__previewProbe"];
  require([probe[@"firstRuntime"] isKindOfClass:NSNumber.class] && [probe[@"firstRuntime"] doubleValue]<.5,
          "Fresh preview did not start in its initial clock phase");
  require([probe[@"noOpener"] boolValue] && [probe[@"noAuthoring"] boolValue] && ![page scriptTestHasEditorSession],
          "Fresh preview found an opener or an authoring capability");
  require([probe[@"zeroSpectrum"] boolValue],"Fresh preview script received nonzero or malformed system spectrum");
  previewVerifyNativeAuthoringDenied(page);
}

static void previewVerifyDeniedRequests(DWWebRuntime* runtime, DWWebPage* editor, NSString* sourceRoot,
                                       NSString* runtimeRoot, NSString* cache) {
  NSString* root=[cache stringByAppendingPathComponent:@"PreviewAttackProject"];
  NSError* error=nil;
  require([NSFileManager.defaultManager copyItemAtPath:sourceRoot toPath:root error:&error],error.localizedDescription.UTF8String ?: "Cannot copy attack-source preview fixture");
  previewWriteScript(root,previewProbeSource(editor,YES));
  NSDictionary* original=previewFileBytes(root);
  DWWebPage* page=previewCreate(runtime,root,runtimeRoot);
  __block NSError* failure=nil;page.onError=^(NSError* value){failure=value;};
  [page start];waitUntil(^{return failure!=nil;},20,"Actual denied preview requests did not expose their native page error");
  previewVerifyProbe(page);
  previewVerifyNativeAuthoringDenied(page);
  NSString* message=failure.localizedDescription;
  fprintf(stderr,"Native preview attack first native error: %s\n",message.UTF8String);
  NSMutableArray<NSString*>* targets=[NSMutableArray array];
  for(NSString* origin in @[page.origin,editor.origin])
    for(NSString* route in @[@"/__editor/config",@"/__editor/event",@"/__editor/resource"])
      [targets addObject:[origin stringByAppendingString:route]];
  [targets addObject:[page.origin stringByAppendingString:@"/__project/scene.json"]];
  BOOL matchesTarget=NO;
  for(NSString* target in targets)if([message containsString:target]){matchesTarget=YES;break;}
  const BOOL identifiesDenial=[message containsString:@"denied"] || [message containsString:@"Content Security Policy"] || [message containsString:@"Refused"];
  require(matchesTarget && identifiesDenial,
          "Preview attack failed for a reason unrelated to the boundary denial");
  require([previewFileBytes(root) isEqual:original],"Preview attack changed its captured project bytes");
  previewClose(page,1,runtime);
  require([NSFileManager.defaultManager removeItemAtPath:root error:&error],error.localizedDescription.UTF8String ?: "Cannot remove released attack-source fixture");
}

static void previewVerifyScriptDiagnostic(DWWebRuntime* runtime, NSString* sourceRoot, NSString* runtimeRoot, NSString* cache) {
  NSString* root=[cache stringByAppendingPathComponent:@"PreviewErrorProject"];
  NSError* error=nil;
  require([NSFileManager.defaultManager copyItemAtPath:sourceRoot toPath:root error:&error],error.localizedDescription.UTF8String ?: "Cannot copy script diagnostic fixture");
  previewWriteScript(root,@"export function init(value){throw new Error('NativePreviewInitFailure');} export function update(value){return value;}");
  NSDictionary* original=previewFileBytes(root);
  DWWebPage* page=previewCreate(runtime,root,runtimeRoot);
  __block NSError* failure=nil;__block NSDictionary* diagnostic=nil;
  page.onError=^(NSError* value){failure=value;};
  page.onDiagnostic=^(NSDictionary* value){if([value[@"message"] containsString:@"NativePreviewInitFailure"])diagnostic=value;};
  [page start];
  waitUntil(^{return diagnostic!=nil||failure!=nil;},20,"Actual preview init exception was not reported to native diagnostics");
  require(diagnostic && [diagnostic[@"level"] isEqual:@"warn"],"Actual preview script exception did not retain its visible engine warning");
  // init diagnostics can arrive before the real first frame. This test closes
  // a running diagnostic preview, so finish preparation before its close check.
  waitUntil(^{return page.ready||failure!=nil;},20,"Script diagnostic preview did not finish its actual first frame");
  require(!failure,"Script diagnostic preview failed during preparation");
  require([previewFileBytes(root) isEqual:original],"Script diagnostic execution changed captured project bytes");
  previewClose(page,1,runtime);
  require([NSFileManager.defaultManager removeItemAtPath:root error:&error],error.localizedDescription.UTF8String ?: "Cannot remove released script diagnostic fixture");
}

static void verifyPreviewBoundary(DWWebRuntime* runtime, NSString* sourceRoot, NSString* editorRuntime,
                                  NSString* previewRuntime, NSString* cache) {
  NSDictionary* sourceBytes=previewFileBytes(sourceRoot);
  NSString* project=[cache stringByAppendingPathComponent:@"PreviewProject"], *resources=[cache stringByAppendingPathComponent:@"PreviewResources"];
  NSError* error=nil;
  require([NSFileManager.defaultManager copyItemAtPath:sourceRoot toPath:project error:&error],error.localizedDescription.UTF8String ?: "Cannot copy owned preview fixture");
  NSDictionary* blank=@{@"title":@"Preview boundary blank workbench",@"entry":@"scene.json",@"project":@{@"type":@"scene",@"file":@"scene.json"},
    @"scene":@{@"general":@{@"orthogonalprojection":@{@"width":@640,@"height":@360},@"clearenabled":@YES,@"clearcolor":@"0.05 0.05 0.08"},@"objects":@[]}};
  __block NSError* editorFailure=nil; __block NSUInteger stageRequests=0;
  DWWebPage* editor=[runtime editorPageWithProjectRoot:sourceRoot runtimeRoot:editorRuntime configuration:@{@"language":@"en",@"document":blank} size:NSMakeSize(1180,760) error:&error];
  require(editor!=nil,error.localizedDescription.UTF8String ?: "Cannot create blank authoring page alongside preview");
  editor.onError=^(NSError* value){editorFailure=value;};
  configureResources(editor,resources,sourceRoot,^(NSError* value){editorFailure=value;});
  void(^resourceHandler)(NSDictionary*)=[editor.onEditorResource copy];
  editor.onEditorResource=^(NSDictionary* request){if([request[@"action"] isEqual:@"stage"])++stageRequests;resourceHandler(request);};
  NSWindow* editorWindow=fkHostWindow(editor);
  [editor start];waitUntil(^{return editor.ready||editorFailure!=nil;},20,"Preview companion Editor first frame timed out");
  require(!editorFailure && [editor editorTestNativeViewIsAttached],"Preview companion Editor failed or is detached");
  command(editor,@{@"type":@"thaw"});
  require([command(editor,@{@"type":@"snapshot"})[@"document"] isEqual:blank],"Preview companion Editor was not blank");
  previewWriteScript(project,previewProbeSource(editor,NO));
  NSDictionary* ownedBytes=previewFileBytes(project);
  DWWebPage* page=previewCreate(runtime,project,previewRuntime);
  __block NSError* failure=nil;page.onError=^(NSError* value){failure=value;};
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Independent preview first frame timed out");
  require(!failure && runtime.activePageCount==2 && ![page.origin isEqual:editor.origin],"Independent preview failed or shared the Editor origin");
  previewVerifyInitialClock(page);
  for(NSString* color in @[@"green",@"red",@"green"])
    waitUntil(^{return previewColor(page,color);},2,"Independent preview did not render actual half-second green/red/green pixels");
  waitUntil(^{return previewColor(page,@"red");},2,"Preview did not reach the pre-restart red phase");
  previewPlaying(page,NO);runFor(.12);
  const double paused=[[page previewTestValue:@"globalThis.__previewProbe.runtime"] doubleValue];
  NSDictionary* frozenPixels=eventPixels(page);runFor(.65);
  require(std::abs([[page previewTestValue:@"globalThis.__previewProbe.runtime"] doubleValue]-paused)<1e-8 && [eventPixels(page) isEqual:frozenPixels],"Acknowledged preview pause did not freeze real script time and pixels");
  NSString* resumedColor=[frozenPixels[@"green"][0] unsignedLongValue]>100?@"red":@"green";
  previewPlaying(page,YES);
  waitUntil(^{return previewColor(page,resumedColor);},2,"Acknowledged preview resume did not advance real pixels");
  require([[page previewTestValue:@"globalThis.__previewProbe.runtime"] doubleValue]>paused,"Acknowledged preview resume did not advance actual script time");
  NSString* oldOrigin=page.origin;
  previewClose(page,1,runtime);require(!editorFailure && editor.ready,"Closing preview broke the independent authoring page");
  page=previewCreate(runtime,project,previewRuntime);failure=nil;page.onError=^(NSError* value){failure=value;};
  require(![page.origin isEqual:oldOrigin] && ![page.origin isEqual:editor.origin],"Restart reused an old preview or Editor origin");
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Restarted preview first frame timed out");
  require(!failure,"Restarted preview failed");previewVerifyInitialClock(page);
  waitUntil(^{return previewColor(page,@"green");},1,"Restarted preview did not render its initial green phase");
  previewClose(page,1,runtime);
  previewVerifyDeniedRequests(runtime,editor,sourceRoot,previewRuntime,cache);
  previewVerifyScriptDiagnostic(runtime,sourceRoot,previewRuntime,cache);
  require([previewFileBytes(project) isEqual:ownedBytes] && [previewFileBytes(sourceRoot) isEqual:sourceBytes],"Preview execution changed captured or source project bytes");
  require(!editorFailure && [command(editor,@{@"type":@"snapshot"})[@"document"] isEqual:blank],"Preview probes changed or broke the blank workbench snapshot");
  NSArray* staged=[NSFileManager.defaultManager contentsOfDirectoryAtPath:resources error:&error];
  require(staged!=nil && staged.count==0 && stageRequests==0,"Preview probes staged native resource blobs");
  previewClose(editor,0,runtime);[editorWindow close];
  require([NSFileManager.defaultManager removeItemAtPath:project error:&error],error.localizedDescription.UTF8String ?: "Cannot remove released owned preview fixture");
  fprintf(stderr,"Native preview: real isolated script probes, half-second pixels, acknowledged freeze/resume, new-origin initial clock, immutable bytes, unchanged surviving Editor and zero-page release passed\n");
}
