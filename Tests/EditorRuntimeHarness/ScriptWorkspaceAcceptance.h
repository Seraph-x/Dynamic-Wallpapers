#pragma once

// This exercises the real CEF command receiver and actual Main pages. The
// production Swift close/save owner remains covered by its separate store tests.

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
  [page editorTestScript:@"document.getElementById('script-source').focus();document.getElementById('script-source').select();"];
  [page clipTestAwait:@"document.activeElement.id==='script-source'"];
  // AppKit keyCode 0 inserts printable characters; textarea newlines require
  // the real Return key (36). Sending LF as a printable event drops the line.
  NSArray<NSString*>* lines=[source componentsSeparatedByString:@"\n"];
  for(NSUInteger index=0;index<lines.count;++index){
    if(index>0)[page gltfTestReturn];
    [page editorTestType:lines[index]];
  }
  [page editorTestAwaitInput:@"#script-source" value:source focused:YES];
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
  [page editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"1\"]').click();document.getElementById('script-workspace').click();"];
  [page clipTestAwait:@"document.getElementById('script-panel')&&!document.getElementById('script-panel').hidden&&document.getElementById('script-target').options.length>0"];
  [page editorTestScript:@"(()=>{const target=document.getElementById('script-target');target.value='color';target.dispatchEvent(new Event('change',{bubbles:true}));})();"];
  fprintf(stderr,"Native Script workspace phase=initial-target\n");
  [page editorTestAwaitInput:@"#script-source" value:[original[@"scene"][@"objects"][0][@"color"][@"script"] stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]];
  fprintf(stderr,"Native Script workspace phase=type-authoring-source\n");
  scriptWorkspaceType(page,[scriptWorkspaceSource() stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]);
  // Freeze must flush the focused source before native ownership captures it.
  fprintf(stderr,"Native Script workspace phase=focused-freeze\n");
  NSDictionary* frozen=command(page,@{@"type":@"freeze"});require([frozen[@"dirty"] boolValue]&&[frozen[@"document"] isEqual:expected],"Focused native source did not commit exact CRLF/Unicode bytes before freeze");
  require([[page previewTestValue:@"document.body.inert"] boolValue],"Native source freeze did not immediately lock authoring");
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:expected],"Native validated source snapshot differs from frozen revision");
  command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native source did not undo in exactly one document revision");
  command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:expected],"Native source redo lost exact expected bytes");
  fprintf(stderr,"Native Script workspace phase=invalid-source\n");
  scriptWorkspaceType(page,@"export function update( {");
  frozen=command(page,@{@"type":@"freeze"});require([frozen[@"dirty"] boolValue]&&[frozen[@"document"] isEqual:expected],"Invalid source freeze lost dirty state or changed canonical source");
  __block BOOL done=NO;__block NSDictionary* rejected=nil;__block NSError* transport=nil;
  [page requestEditorCommand:@{@"type":@"snapshot"} completion:^(NSDictionary* value,NSError* error){rejected=value;transport=error;done=YES;}];
  waitUntil(^{return done;},8,"Invalid source snapshot did not respond");require(!transport&&[rejected[@"error"] length]>0,"Invalid source snapshot must explicitly reject its compiler error");
  command(page,@{@"type":@"thaw"});[page editorTestAwaitInput:@"#script-source" value:@"export function update( {"];
  [page clipTestAwait:@"!document.body.inert&&document.getElementById('script-source').getAttribute('aria-invalid')==='true'&&document.getElementById('script-diagnostics').textContent.trim().length>0"];
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
