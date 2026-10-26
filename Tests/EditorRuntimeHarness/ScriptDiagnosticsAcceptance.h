#pragma once

static NSString* diagnosticsCapturedSource() {
  return @"// diagnostic capture — 雪\r\nexport function init(value) {\r\n  throw new Error('NativeDiagnosticInit');\r\n}\r\nexport function update(value) {\r\n  throw new Error('NativeDiagnosticUpdate');\r\n}\r\n";
}
static NSString* diagnosticsLayerName() {
  return [@"Captured — " stringByAppendingString:[@"雪😀" stringByPaddingToLength:9000 withString:@"雪😀" startingAtIndex:0]];
}
static NSString* diagnosticsJSON(id value) {
  NSError* error=nil;NSData* bytes=[NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
  require(bytes!=nil,error.localizedDescription.UTF8String ?: "Cannot serialize diagnostics oracle");
  return [[NSString alloc]initWithData:bytes encoding:NSUTF8StringEncoding];
}
static NSDictionary* diagnosticsScene() {
  return @{@"general":@{@"orthogonalprojection":@{@"width":@640,@"height":@360},@"clearenabled":@YES,@"clearcolor":@"0 0 0",@"cameraparallax":@NO,
    @"zoom":@{@"value":@1,@"script":@"export function update(value) { throw new Error('NativeDiagnosticGeneral'); }"}},
    @"objects":@[@{@"id":@1,@"name":diagnosticsLayerName(),@"image":@"models/editor/rig.json",@"origin":@"320 180 0",@"size":@"100 30",@"scale":@"1 1 1",@"angles":@"0 0 0",
      @"color":@{@"value":@"0 1 0",@"script":diagnosticsCapturedSource()},
      @"alpha":@{@"value":@1,@"script":@"export function update(value) { throw new Error('a'.repeat(199)+'😀tail'); }"},
      @"effects":@[@{@"file":@"effects/editor/migration.json",@"visible":@{@"value":@YES,@"script":@"export function update(value) { throw new Error('NativeDiagnosticEffect'); }"},@"passes":@[]}]}]};
}
static DWWebPage* diagnosticsPreview(DWWebRuntime* runtime,NSString* root,NSString* runtimeRoot,NSString* sceneID,uint64_t generation,NSMutableDictionary* issues,NSMutableArray* rawReports,void(^received)(),void(^failed)(NSError*)) {
  NSError* error=nil;DWWebPage* page=[runtime scenePageWithProjectRoot:root runtimeRoot:runtimeRoot entry:@"scene.json" representation:@"loose" sceneID:sceneID generation:generation size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Cannot create actual diagnostics preview");
  require(![page scriptTestHasEditorSession],"Diagnostics preview acquired authoring APIs");
  page.onError=failed;
  page.onSceneScriptIssue=^(NSDictionary* issue){
    require(issue.count==7,"Native actual issue schema gained unexpected fields");
    issues[[NSString stringWithFormat:@"%@/%@",issue[@"target"],issue[@"phase"]]]=issue;
    received();
  };
  page.onSceneScriptRawIssue=^(NSString* rawJSON){[rawReports addObject:rawJSON];};
  require([page setOutputGain:0 error:&error],"Cannot mute actual diagnostics preview");
  [page start];return page;
}
static void diagnosticsAwaitIssues(DWWebPage* page,NSMutableDictionary* issues,NSMutableArray* rawReports,NSError* __strong* failure) {
  waitUntil(^{return BOOL(*failure!=nil||(page.ready&&[rawReports.lastObject containsString:@"\"count\":3"]&&[issues[@"color/update"][@"count"] isEqual:@3]&&[issues[@"general.zoom/update"][@"count"] isEqual:@3]&&[issues[@"effects[0].visible/update"][@"count"] isEqual:@3]));},20,"Actual CEF issue callback/counts did not arrive");
  require(!*failure,(*failure).localizedDescription.UTF8String ?: "Actual diagnostics preview failed");
  require(rawReports.count>0,"Actual truncated-emoji diagnostic was not retained");
  BOOL countThree=NO;
  for(NSString* rawJSON in rawReports){
    require([rawJSON containsString:@"\\ud83d"]&&![rawJSON containsString:@"\\ude00"]&&![rawJSON containsString:@"�"],"Raw diagnostic altered an unpaired UTF16 code unit");
    NSString* checked=[rawJSON stringByReplacingOccurrencesOfString:@"\\ud83d" withString:@"\\\\ud83d"];
    NSDictionary* issue=[NSJSONSerialization JSONObjectWithData:[checked dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    require(issue.count==7&&[issue[@"target"] isEqual:@"alpha"]&&[issue[@"message"] isEqual:[[@"a" stringByPaddingToLength:199 withString:@"a" startingAtIndex:0] stringByAppendingString:@"\\ud83d"]],"Raw mode failed to preserve the original issue JSON and truncated message");
    countThree=countThree||[issue[@"count"] isEqual:@3];
  }
  require(countThree,"Raw-mode diagnostic did not retain the engine's actual final count");
  NSDictionary* init=issues[@"color/init"],*update=issues[@"color/update"],*general=issues[@"general.zoom/update"];
  require([init[@"message"] isEqual:@"NativeDiagnosticInit"]&&[init[@"line"] isEqual:@3]&&[init[@"count"] isEqual:@1],"Actual CEF init issue did not match independently authored source line 3");
  require([update[@"message"] isEqual:@"NativeDiagnosticUpdate"]&&[update[@"line"] isEqual:@6]&&[update[@"layerId"] isEqual:@1],"Actual CEF update issue did not match independently authored source line 6");
  require([init[@"layerName"] isEqual:diagnosticsLayerName()]&&[update[@"layerName"] isEqual:diagnosticsLayerName()],"Lossless native chunk delivery changed the >8192-byte Unicode layer name");
  NSDictionary* effect=issues[@"effects[0].visible/update"];
  require([effect[@"layerId"] isEqual:@1]&&[effect[@"line"] isEqual:@1]&&[effect[@"message"] isEqual:@"NativeDiagnosticEffect"],"Actual effect issue lost its structural target or independently authored line 1");
  require([general[@"layerId"] isEqual:NSNull.null]&&[general[@"layerName"] isEqual:@""]&&[general[@"line"] isEqual:@1]&&[general[@"message"] isEqual:@"NativeDiagnosticGeneral"],"Actual general issue fabricated a layer anchor or source line");
}
static NSDictionary* diagnosticsLink(NSDictionary* capture,NSDictionary* issue) {
  require([issue[@"layerId"] isEqual:@1]&&[issue[@"target"] isEqual:@"color"],"Source navigation must originate in the actual captured issue");
  NSString* source=capture[@"document"][@"scene"][@"objects"][0][@"color"][@"script"];
  require([source isEqual:diagnosticsCapturedSource()],"Captured source bytes differ from the independent CRLF oracle");
  return @{@"documentIdentity":capture[@"documentIdentity"],@"source":source,@"layerId":issue[@"layerId"],@"target":issue[@"target"],@"path":@[@"objects",@0,@"color",@"script"],@"line":issue[@"line"],@"registered":@YES};
}
static void diagnosticsAssertCaptured(DWWebPage* editor,NSString* reason) {
  [editor clipTestAwait:@"Boolean(document.getElementById('script-captured-dialog')?.open&&document.querySelector('#script-captured-source .cm-content'))"];
  NSDictionary* actual=[editor previewTestValue:@"(()=>{const {EditorView,EditorState}=window.__codeAcceptanceAPI,content=document.querySelector('#script-captured-source .cm-content'),view=EditorView.findFromDOM(content);return {source:view.state.sliceDoc(),readOnly:view.state.facet(EditorState.readOnly),editable:view.state.facet(EditorView.editable),reason:document.getElementById('script-captured-reason').textContent,selection:view.state.selection.main.from};})()"];
  require([actual[@"source"] isEqual:[diagnosticsCapturedSource() stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]]&&[actual[@"readOnly"] boolValue]&&![actual[@"editable"] boolValue],"Captured native CodeMirror changed source bytes or permits edits");
  require([actual[@"reason"] containsString:reason],"Captured source did not explain pending/stale provenance");
  [editor editorTestScript:@"document.getElementById('script-captured-find').click();"];
  [editor clipTestAwait:@"Boolean(document.querySelector('#script-captured-source .cm-search input[name=search]'))"];
  [editor editorTestScript:@"document.getElementById('script-captured-close').click();"];
  [editor clipTestAwait:@"!document.getElementById('script-captured-dialog').open"];
}
static void verifyScriptDiagnostics(DWWebRuntime* runtime,NSString* sourceRoot,NSString* editorRuntime,NSString* previewRuntime,NSString* cache) {
  NSError* error=nil;NSString* root=[cache stringByAppendingPathComponent:@"DiagnosticsCapture"],*resourceRoot=[cache stringByAppendingPathComponent:@"DiagnosticsResources"];
  NSDictionary* originalFiles=previewFileBytes(sourceRoot);
  require([NSFileManager.defaultManager copyItemAtPath:sourceRoot toPath:root error:&error],error.localizedDescription.UTF8String ?: "Cannot copy owned diagnostics fixture");
  NSDictionary* scene=diagnosticsScene(),*project=clipJSON([root stringByAppendingPathComponent:@"project.json"]);
  NSData* sceneBytes=[diagnosticsJSON(scene) dataUsingEncoding:NSUTF8StringEncoding];
  require([sceneBytes writeToFile:[root stringByAppendingPathComponent:@"scene.json"] options:NSDataWritingAtomic error:&error],"Cannot write owned diagnostics scene");
  NSDictionary* material=@{@"passes":@[@{@"shader":@"editor/migration",@"textures":@[],@"blending":@"normal",@"constantshadervalues":@{@"alpha":@1}}]};
  require([[diagnosticsJSON(material) dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[root stringByAppendingPathComponent:@"materials/editor/migration.json"] options:NSDataWritingAtomic error:&error],"Cannot write owned effect material without unrelated scripts");
  NSDictionary* capturedFiles=previewFileBytes(root),*document=@{@"title":@"Native diagnostics capture",@"entry":@"scene.json",@"project":project,@"scene":scene};
  __block NSError* editorFailure=nil;__block NSUInteger stageRequests=0;
  DWWebPage* editor=[runtime editorPageWithProjectRoot:root runtimeRoot:editorRuntime configuration:@{@"language":@"en",@"document":document} size:NSMakeSize(1180,760) error:&error];
  require(editor!=nil,error.localizedDescription.UTF8String ?: "Cannot create diagnostic owner workbench");editor.onError=^(NSError* value){editorFailure=value;};
  configureResources(editor,resourceRoot,root,^(NSError* value){editorFailure=value;});void(^resourceHandler)(NSDictionary*)=[editor.onEditorResource copy];
  editor.onEditorResource=^(NSDictionary* request){if([request[@"action"] isEqual:@"stage"])++stageRequests;resourceHandler(request);};
  NSWindow* window=fkHostWindow(editor);[editor start];waitUntil(^{return editor.ready||editorFailure!=nil;},20,"Diagnostic owner first frame timed out");
  require(!editorFailure&&[editor editorTestNativeViewIsAttached],"Diagnostic owner must be a real attached native CEF page");command(editor,@{@"type":@"thaw"});
  NSDictionary* capture=command(editor,@{@"type":@"snapshot"});require([capture[@"document"] isEqual:document],"Diagnostic owner source changed before preview capture");
  NSString* sceneID=NSUUID.UUID.UUIDString;NSMutableDictionary* issues=[NSMutableDictionary dictionary];NSMutableArray* rawReports=[NSMutableArray array];__block NSError* previewFailure=nil;__block NSUInteger issueEvents=0;
  DWWebPage* preview=diagnosticsPreview(runtime,root,previewRuntime,sceneID,1,issues,rawReports,^{++issueEvents;},^(NSError* value){previewFailure=value;});
  diagnosticsAwaitIssues(preview,issues,rawReports,&previewFailure);
  const NSUInteger retained=issueEvents;runFor(.15);require(issueEvents==retained,"Disabled callbacks fabricated new retained counts");
  NSDictionary* link=diagnosticsLink(capture,issues[@"color/update"]);
  NSDictionary* current=command(editor,@{@"type":@"reveal-script",@"link":link});require([current[@"navigation"][@"kind"] isEqual:@"current"],"Actual issue did not navigate to the exact current source");
  scriptWorkspaceInstallInspection(editor);scriptWorkspaceAwaitSource(editor,[diagnosticsCapturedSource() stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]);
  NSDictionary* selection=[editor previewTestValue:@"(()=>{const view=window.__codeAcceptanceAPI.EditorView.findFromDOM(document.querySelector('#script-source .cm-content')),range=view.state.selection.main;return {line:view.state.doc.lineAt(range.from).number,text:view.state.sliceDoc(range.from,range.to)};})()"];
  require([selection[@"line"] isEqual:@6]&&[selection[@"text"] containsString:@"NativeDiagnosticUpdate"],"Native issue navigation did not reveal actual reported source line 6");
  require([command(editor,@{@"type":@"snapshot"})[@"document"] isEqual:document],"Current issue navigation changed canonical project bytes");
  scriptWorkspaceType(editor,@"export function update( {");
  NSDictionary* pending=command(editor,@{@"type":@"reveal-script",@"link":link});require([pending[@"navigation"][@"reason"] isEqual:@"pending"],"Invalid pending native draft was flushed by source navigation");
  diagnosticsAssertCaptured(editor,@"Finish or revert");scriptWorkspaceAwaitSource(editor,@"export function update( {");
  [editor editorTestScript:@"document.getElementById('script-revert').click();"];scriptWorkspaceAwaitSource(editor,[diagnosticsCapturedSource() stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]);
  require([command(editor,@{@"type":@"snapshot"})[@"document"] isEqual:document],"Captured viewing or pending-draft revert changed the original document");
  NSString* changedSource=@"export function update(value){ return {x:1,y:0,z:0}; }";scriptWorkspaceType(editor,changedSource);
  NSDictionary* changed=command(editor,@{@"type":@"snapshot"})[@"document"];
  require([changed[@"scene"][@"objects"][0][@"color"][@"script"] isEqual:changedSource],"Native stale-source fixture did not commit its exact authored source");
  NSDictionary* stale=command(editor,@{@"type":@"reveal-script",@"link":link});require([stale[@"navigation"][@"reason"] isEqual:@"source"],"Changed current source was confused with the captured revision");
  diagnosticsAssertCaptured(editor,@"differs");scriptWorkspaceAwaitSource(editor,changedSource);
  require([command(editor,@{@"type":@"snapshot"})[@"document"] isEqual:changed],"Stale captured viewer changed the current source");
  command(editor,@{@"type":@"undo"});require([command(editor,@{@"type":@"snapshot"})[@"document"] isEqual:document],"Read-only navigation inserted a canonical undo revision");
  previewClose(preview,1,runtime);require(preview.onSceneScriptIssue==nil&&preview.onSceneScriptRawIssue==nil,"Closed preview retained a native issue callback");
  const NSUInteger retiredEvents=issueEvents;NSMutableDictionary* restarted=[NSMutableDictionary dictionary];NSMutableArray* rawRestarted=[NSMutableArray array];__block NSUInteger restartEvents=0;previewFailure=nil;
  DWWebPage* replacement=diagnosticsPreview(runtime,root,previewRuntime,sceneID,2,restarted,rawRestarted,^{++restartEvents;},^(NSError* value){previewFailure=value;});
  require(restarted.count==0,"Fresh preview issue retention did not reset before load");diagnosticsAwaitIssues(replacement,restarted,rawRestarted,&previewFailure);
  require([restarted[@"color/init"][@"count"] isEqual:@1]&&restartEvents>0&&issueEvents==retiredEvents,"Restart inherited counts or accepted retired-page events");
  require([previewFileBytes(root) isEqual:capturedFiles]&&[previewFileBytes(sourceRoot) isEqual:originalFiles],"Preview restart or navigation changed captured/source files");
  previewClose(replacement,1,runtime);previewClose(editor,0,runtime);[window close];
  require(!editorFailure&&stageRequests==0,"Diagnostics workbench failed or staged authoring resources");
  require([NSFileManager.defaultManager removeItemAtPath:root error:&error],"Released diagnostics snapshot still has native resource ownership");
  fprintf(stderr,"Native script diagnostics: genuine CEF callbacks, lossless large Unicode names, exact CRLF lines/counts, current/pending/stale navigation, untouched history/capture and reset/retired cleanup passed\n");
}
