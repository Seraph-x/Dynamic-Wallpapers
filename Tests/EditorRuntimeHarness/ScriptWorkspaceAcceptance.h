#pragma once

// This exercises the real CEF command receiver and actual Main pages. The
// production Swift close/save owner remains covered by its separate store tests.

@interface DWWebPage (CodeEditorAcceptance)
- (void)codeTestShortcut:(NSString*)character code:(unsigned short)code;
- (void)codeTestChord:(NSString*)character code:(unsigned short)code modifiers:(NSEventModifierFlags)modifiers;
@end
@implementation DWWebPage (CodeEditorAcceptance)
- (void)codeTestShortcut:(NSString*)character code:(unsigned short)code {
  [self codeTestChord:character code:code modifiers:NSEventModifierFlagCommand];
}
- (void)codeTestChord:(NSString*)character code:(unsigned short)code modifiers:(NSEventModifierFlags)modifiers {
  @autoreleasepool {
    _resources->state->browser->GetHost()->SetFocus(true);
    NSView* child=(__bridge NSView*)_resources->state->browser->GetHost()->GetWindowHandle();
    for(const NSEventType type:{NSEventTypeKeyDown,NSEventTypeKeyUp}){
      NSEvent* event=[NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:modifiers timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:child.window.windowNumber context:nil characters:character charactersIgnoringModifiers:character isARepeat:NO keyCode:code];
      [NSApp sendEvent:event];
    }
  }
}
@end
static void scriptWorkspaceInstallInspection(DWWebPage* page) {
  // The imported public API is used only to read the real CodeMirror state.
  [page editorTestScript:@"import(new URL('./code-editor-api.mjs',location.href)).then(api=>{window.__codeAcceptanceAPI=api;});"];
  [page clipTestAwait:@"Boolean(window.__codeAcceptanceAPI?.EditorView&&document.querySelector('#script-source .cm-content'))"];
}
static void scriptWorkspaceOpenColor(DWWebPage* page) {
  [page editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"1\"]').click();"];
  command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"document.getElementById('script-workspace').click();"];
  command(page,@{@"type":@"snapshot"});
  [page clipTestAwait:@"!document.getElementById('script-panel').hidden&&!document.getElementById('script-target').disabled&&[...document.getElementById('script-target').options].some(option=>option.value==='color')"];
  [page editorTestScript:@"(()=>{const target=document.getElementById('script-target');target.value='color';target.dispatchEvent(new Event('change',{bubbles:true}));})();"];
  command(page,@{@"type":@"snapshot"});
}
static void scriptWorkspaceAwaitSource(DWWebPage* page,NSString* source,BOOL focused=NO) {
  NSString* json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:@{@"source":source,@"focused":@(focused)} options:0 error:nil] encoding:NSUTF8StringEncoding];
  try {
    [page clipTestAwait:[NSString stringWithFormat:@"(()=>{const expected=%@,content=document.querySelector('#script-source .cm-content'),view=window.__codeAcceptanceAPI.EditorView.findFromDOM(content);return view&&view.state.sliceDoc()===expected.source&&(!expected.focused||document.activeElement===content);})()",json]];
  } catch(...) {
    id state=[page previewTestValue:@"(()=>{const {EditorView,EditorState}=window.__codeAcceptanceAPI,content=document.querySelector('#script-source .cm-content'),view=EditorView.findFromDOM(content);return {source:view.state.sliceDoc(),readOnly:view.state.facet(EditorState.readOnly),editable:view.state.facet(EditorView.editable),active:document.activeElement?.outerHTML,selectedCompletion:document.querySelector('.cm-tooltip-autocomplete [aria-selected=true]')?.textContent??null};})()"];
    fprintf(stderr,"Native CodeMirror source mismatch: %s\n",[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:state options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);throw;
  }
}
static BOOL scriptWorkspaceReadOnly(DWWebPage* page) {
  return [[page previewTestValue:@"(()=>{const {EditorView,EditorState}=window.__codeAcceptanceAPI,content=document.querySelector('#script-source .cm-content'),view=EditorView.findFromDOM(content);return view.state.facet(EditorState.readOnly)&&view.state.facet(EditorView.editable)===false&&content.getAttribute('contenteditable')==='false';})()"] boolValue];
}
static NSString* scriptWorkspaceSource() {
  return @"// workspace authored — 雪\r\nexport function update(value){\r\n  return {x:1,y:0,z:0};\r\n}\r\n";
}
static NSDictionary* scriptWorkspaceExpected(NSDictionary* original) {
  NSMutableDictionary* result=[original mutableCopy],*scene=[original[@"scene"] mutableCopy];NSMutableArray* objects=[scene[@"objects"] mutableCopy];
  require(objects.count==3&&[objects[0][@"id"] isEqual:@1],"Script workspace requires its actual migration rig fixture");
  NSMutableDictionary* layer=[objects[0] mutableCopy],*color=[layer[@"color"] mutableCopy];
  require([color[@"value"] isEqual:@"0 1 0"]&&[color[@"future"][@"keep"] boolValue],"Script workspace lost base or future wrapper metadata");
  color[@"script"]=scriptWorkspaceSource();layer[@"color"]=color;objects[0]=layer;scene[@"objects"]=objects;result[@"scene"]=scene;return result;
}
static void scriptWorkspaceType(DWWebPage* page,NSString* source) {
  [page clipTestAwait:@"(()=>{const {EditorView,EditorState}=window.__codeAcceptanceAPI,view=EditorView.findFromDOM(document.querySelector('#script-source .cm-content'));return view&&!view.state.facet(EditorState.readOnly)&&view.state.facet(EditorView.editable);})()"];
  [page editorTestScript:@"document.querySelector('#script-source .cm-content').focus();"];
  [page clipTestAwait:@"document.activeElement===document.querySelector('#script-source .cm-content')"];
  [page codeTestShortcut:@"a" code:0];
  // Real Return invokes CodeMirror's indentation. Indent-on-input removes the
  // closing brace's automatic indent; the independent oracle remains exact.
  NSArray<NSString*>* lines=[source componentsSeparatedByString:@"\n"];
  for(NSUInteger index=0;index<lines.count;++index){
    if(index>0)[page gltfTestReturn];
    [page editorTestType:[lines[index] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
  }
  // Auto-close brackets may leave a generated suffix after all requested bytes.
  // First prove the independently expected prefix/cursor, then remove only that
  // generated tail with actual selection/Delete input, as an author would.
  NSString* literal=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:@{@"source":source} options:0 error:nil] encoding:NSUTF8StringEncoding];
  [page clipTestAwait:[NSString stringWithFormat:@"(()=>{const expected=%@,view=window.__codeAcceptanceAPI.EditorView.findFromDOM(document.querySelector('#script-source .cm-content')),source=view.state.sliceDoc(),selection=view.state.selection.main;return source.startsWith(expected.source)&&selection.empty&&selection.head===expected.source.length;})()",literal]];
  NSString* tail=[page previewTestValue:[NSString stringWithFormat:@"(()=>{const expected=%@,view=window.__codeAcceptanceAPI.EditorView.findFromDOM(document.querySelector('#script-source .cm-content'));return view.state.sliceDoc().slice(expected.source.length);})()",literal]];
  if(tail.length){
    require([tail rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\n\r\t )]}"].invertedSet].location==NSNotFound,"Native source input left unexpected non-bracket text after its exact authored prefix");
    unichar arrow=NSDownArrowFunctionKey;
    [page codeTestChord:[NSString stringWithCharacters:&arrow length:1] code:125 modifiers:NSEventModifierFlagCommand|NSEventModifierFlagShift];
    [page clipTestKey:@"\177" code:51];
  }
  scriptWorkspaceAwaitSource(page,source,YES);
}
static void verifyScriptWorkspace(DWWebRuntime* runtime,NSString* projectRoot,NSString* editorRuntime,NSString* cache,NSString* sourcePath,NSString* expectedPath) {
  NSDictionary* original=clipJSON(sourcePath),*expected=scriptWorkspaceExpected(original);require([clipJSON(expectedPath) isEqual:expected],"Browser output differs from independently known native source bytes");
  NSDictionary* sourceFiles=previewFileBytes(projectRoot);NSString* resources=[cache stringByAppendingPathComponent:@"ScriptWorkspaceResources"];
  NSError* error=nil;__block NSError* failure=nil;__block NSUInteger stages=0;
  DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:editorRuntime configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native script workspace creation failed");page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});
  void(^resourceHandler)(NSDictionary*)=[page.onEditorResource copy];page.onEditorResource=^(NSDictionary* event){if([event[@"action"] isEqual:@"stage"])++stages;resourceHandler(event);};
  NSWindow* window=fkHostWindow(page);[page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native script workspace first frame timed out");require(!failure&&[page editorTestNativeViewIsAttached]&&[page scriptTestHasEditorSession],"Script workspace requires real attached CEF input");
  command(page,@{@"type":@"thaw"});
  scriptWorkspaceOpenColor(page);
  fprintf(stderr,"Native Script workspace phase=initial-target\n");
  scriptWorkspaceInstallInspection(page);
  scriptWorkspaceAwaitSource(page,[original[@"scene"][@"objects"][0][@"color"][@"script"] stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]);
  fprintf(stderr,"Native Script workspace phase=type-authoring-source\n");
  scriptWorkspaceType(page,[scriptWorkspaceSource() stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]);
  // Freeze must flush the focused source before native ownership captures it.
  fprintf(stderr,"Native Script workspace phase=focused-freeze\n");
  NSDictionary* frozen=command(page,@{@"type":@"freeze"});require([frozen[@"dirty"] boolValue]&&[frozen[@"document"] isEqual:expected],"Focused native source did not commit exact CRLF/Unicode bytes before freeze");
  require([[page previewTestValue:@"document.body.inert"] boolValue]&&scriptWorkspaceReadOnly(page),"Native source freeze did not lock both CodeMirror state and DOM");
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:expected],"Native validated source snapshot differs from frozen revision");
  command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native source did not undo in exactly one document revision");
  command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:expected],"Native source redo lost exact expected bytes");
  fprintf(stderr,"Native Script workspace phase=invalid-source\n");
  scriptWorkspaceType(page,@"export function update( {");
  frozen=command(page,@{@"type":@"freeze"});require([frozen[@"dirty"] boolValue]&&[frozen[@"document"] isEqual:expected],"Invalid source freeze lost dirty state or changed canonical source");
  __block BOOL done=NO;__block NSDictionary* rejected=nil;__block NSError* transport=nil;
  [page requestEditorCommand:@{@"type":@"snapshot"} completion:^(NSDictionary* value,NSError* error){rejected=value;transport=error;done=YES;}];
  waitUntil(^{return done;},8,"Invalid source snapshot did not respond");require(!transport&&[rejected[@"error"] length]>0,"Invalid source snapshot must explicitly reject its compiler error");
  command(page,@{@"type":@"thaw"});scriptWorkspaceAwaitSource(page,@"export function update( {");
  [page clipTestAwait:@"!document.body.inert&&document.querySelector('#script-source .cm-content').getAttribute('aria-invalid')==='true'&&document.getElementById('script-diagnostics').textContent.trim().length>0"];
  [page editorTestScript:@"document.getElementById('script-revert').click();"];
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:expected],"Native invalid-source recovery modified committed document");
  command(page,@{@"type":@"mark-saved",@"document":expected});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native source save acknowledgement remained dirty");command(page,@{@"type":@"thaw"});
  migrationVerifyQuiet(page);require([page previewTestValue:@"globalThis.__workspaceMustNotRun??null"]==NSNull.null,"Authored source executed inside native workbench");
  require(stages==0&&[previewFileBytes(projectRoot) isEqual:sourceFiles],"Native source-only edit staged resources or modified fixture files");
  previewClose(page,0,runtime);[window close];
  fprintf(stderr,"Native Script workspace: attached CEF Unicode/CRLF input, focused freeze/snapshot, one-step history, invalid freeze/rejection/thaw/revert and save acknowledgement passed\n");
}
static void verifyScriptWorkspaceExport(DWWebRuntime* runtime,NSString* root,NSString* mainRuntime,BOOL package) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:root runtimeRoot:mainRuntime entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Authored script Main playback creation failed");require(![page scriptTestHasEditorSession],"Authored Main playback acquired an Editor session");page.onError=^(NSError* value){failure=value;};[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Authored Main playback first frame timed out");require(!failure,"Authored Main playback failed");
  waitUntil(^{return previewColor(page,@"red");},2,"Actual authored source did not render red pixels in both model meshes");
  NSDictionary* probe=[page previewTestValue:@"new Promise(resolve=>{const poll=()=>{const p=globalThis.__migrationProbe;if(['text','effect','material','general'].every(name=>p?.[name]?.top>0&&p[name].init>0&&p[name].update>0))resolve(p);else setTimeout(poll,5);};poll();})"];
  require(probe.count==4&&probe[@"object"]==nil,"Export did not replace just the authored object source and execute remaining anchors");
  require([[page previewTestValue:@"typeof globalThis.__dynamicWallpaperEditor"] isEqual:@"undefined"]&&![page scriptTestHasEditorSession],"Main playback exposed the Editor bridge");
  require([page previewTestValue:@"globalThis.__migrationUnknownMetadataRan??null"]==NSNull.null,"Main executed unsupported source metadata");
  previewClose(page,0,runtime);fprintf(stderr,"Main Script workspace %s: authored red mesh pixels, four preserved script anchors, unsupported metadata untouched and no Editor bridge passed\n",package?"PKG":"loose");
}
