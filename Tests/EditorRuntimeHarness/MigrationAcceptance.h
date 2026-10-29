#pragma once

static void migrationVerifyQuiet(DWWebPage* page) {
  NSDictionary* state=[page previewTestValue:@"({probe:globalThis.__migrationProbe??null,unknown:globalThis.__migrationUnknownMetadataRan??null})"];
  require(state[@"probe"]==NSNull.null&&state[@"unknown"]==NSNull.null,"Imported source executed inside the native authoring origin");
}

static void migrationVerifyPlayback(DWWebRuntime* runtime, NSString* root, NSString* runtimeRoot, BOOL package, double expectedAlpha=1, NSString* editorOrigin=nil) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:root runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Migration playback creation failed");page.onError=^(NSError* value){failure=value;};
  require(!editorOrigin||![page.origin isEqual:editorOrigin],"Independent runtime reused the authoring origin");
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Migration playback first frame timed out");require(!failure,"Migration playback failed");
  NSDictionary* probe=[page previewTestValue:@"new Promise(resolve=>{const poll=()=>{const probe=globalThis.__migrationProbe;if(['object','text','effect','material','general'].every(name=>probe?.[name]?.top>0&&probe[name].init>0&&probe[name].update>0))resolve(probe);else setTimeout(poll,5);};poll();})"];
  require(probe.count==5,"Migration playback did not execute exactly the five supported fixture anchors");
  require(std::abs([probe[@"material"][@"layerAlpha"] doubleValue]-expectedAlpha)<1e-6,"Independent runtime did not read the actual captured material-layer revision");
  require([[page previewTestValue:@"({unknown:globalThis.__migrationUnknownMetadataRan??null,authoring:typeof globalThis.__dynamicWallpaperEditor,opener:window.opener===null})"][@"authoring"] isEqual:@"undefined"],"Migration playback acquired the authoring bridge");
  require([page previewTestValue:@"globalThis.__migrationUnknownMetadataRan??null"]==NSNull.null,"Unknown script metadata unexpectedly executed");
  // Both model meshes visibly turn red; green image/text alone cannot pass.
  waitUntil(^{return previewColor(page,@"red");},2,"Independent migration playback did not render actual scripted red pixels in both model meshes");
  waitUntil(^{return previewColor(page,@"green");},2,"Independent migration playback did not render its scripted green phase");
  previewVerifyNativeAuthoringDenied(page);
  previewClose(page,0,runtime);
}

static void migrationVerifyMissingHandler(DWWebRuntime* runtime, NSString* root, NSString* runtimeRoot, NSString* resources) {
  NSDictionary* blank=@{@"title":@"Missing preview handler",@"entry":@"scene.json",@"project":@{@"type":@"scene",@"file":@"scene.json"},@"scene":@{@"general":@{@"orthogonalprojection":@{@"width":@640,@"height":@360}},@"objects":@[]}};
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:root runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":blank} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Missing-handler Editor creation failed");page.onError=^(NSError* value){failure=value;};
  configureResources(page,resources,root,^(NSError* value){failure=value;});
  NSWindow* window=fkHostWindow(page);[page start];waitUntil(^{return page.ready||failure!=nil;},20,"Missing-handler Editor first frame timed out");
  require(!failure&&page.onEditorPreview==nil,"Missing-handler Editor was not actually unhandled");command(page,@{@"type":@"thaw"});
  [page editorTestScript:@"document.getElementById('run-preview').focus();"];[page clipTestAwait:@"document.activeElement.id==='run-preview'"];[page gltfTestReturn];
  waitUntil(^{return failure!=nil;},6,"Unhandled Run event did not expose its native error");
  require([failure.localizedDescription containsString:@"Editor preview handler unavailable"],"Unhandled Run failed for an unrelated reason");
  previewClose(page,0,runtime);[window close];
}

// DWWebPage completion errors describe native transport. The Editor command
// result reports JavaScript rejection in its error field, as the Swift owner does.
static NSError* migrationCommandError(NSDictionary* reply, NSError* transportError) {
  if(transportError)return transportError;
  if(!reply)return [NSError errorWithDomain:@"MigrationAcceptance" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Editor command returned no result"}];
  NSString* message=[reply[@"error"] isKindOfClass:NSString.class]?reply[@"error"]:nil;
  return message?[NSError errorWithDomain:@"MigrationAcceptance" code:2 userInfo:@{NSLocalizedDescriptionKey:message}]:nil;
}

static void verifyMigration(DWWebRuntime* runtime, NSString* projectRoot, NSString* editorRuntime,
                            NSString* previewRuntime, NSString* mainRuntime, NSString* packageRoot,
                            NSString* documentPath, NSString* cache) {
  NSDictionary* original=clipJSON(documentPath);
  NSDictionary* sourceBytes=previewFileBytes(projectRoot);
  NSString* resources=[cache stringByAppendingPathComponent:@"MigrationResources"];
  NSError* error=nil;__block NSError* failure=nil;__block NSUInteger stages=0,requests=0,completed=0;
  __block NSDictionary* captured=nil;__block NSError* rejected=nil;
  DWWebPage* editor=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:editorRuntime configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(editor!=nil,error.localizedDescription.UTF8String ?: "Migration Editor creation failed");
  editor.onError=^(NSError* value){failure=value;};configureResources(editor,resources,projectRoot,^(NSError* value){failure=value;});
  void(^resourceHandler)(NSDictionary*)=[editor.onEditorResource copy];editor.onEditorResource=^(NSDictionary* event){if([event[@"action"] isEqual:@"stage"])++stages;resourceHandler(event);};
  // The real Editor event dispatch invokes this native test receiver. The owning
  // Swift controller's exportPreview path has separate injected-service tests.
  __weak DWWebPage* weakEditor=editor;
  editor.onEditorPreview=^{
    DWWebPage* receiver=weakEditor;
    ++requests;captured=nil;rejected=nil;
    [receiver requestEditorCommand:@{@"type":@"freeze"} completion:^(NSDictionary* state,NSError* freezeError){
      NSError* freezeFailure=migrationCommandError(state,freezeError);
      if(freezeFailure){failure=freezeFailure;++completed;return;}
      [receiver requestEditorCommand:@{@"type":@"snapshot"} completion:^(NSDictionary* snapshot,NSError* snapshotError){
        NSError* snapshotFailure=migrationCommandError(snapshot,snapshotError);
        if(snapshotFailure)rejected=snapshotFailure;else if([snapshot[@"document"] isEqual:state[@"document"]])captured=state[@"document"];else failure=[NSError errorWithDomain:@"MigrationAcceptance" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Freeze and validated snapshot differ"}];
        [receiver requestEditorCommand:@{@"type":@"thaw"} completion:^(NSDictionary* thaw,NSError* thawError){NSError* thawFailure=migrationCommandError(thaw,thawError);if(thawFailure)failure=thawFailure;++completed;}];
      }];
    }];
  };
  NSWindow* window=fkHostWindow(editor);[editor start];waitUntil(^{return editor.ready||failure!=nil;},20,"Migration Editor first frame timed out");require(!failure,"Migration Editor failed");command(editor,@{@"type":@"thaw"});migrationVerifyQuiet(editor);
  command(editor,@{@"type":@"seek",@"time":@.5});migrationVerifyQuiet(editor);
  [editor editorTestScript:@"document.getElementById('project-title').focus();document.getElementById('project-title').select();"];
  [editor editorTestAwaitInput:@"#project-title" value:@"Script migration" focused:YES];[editor editorTestType:@"Native migration draft"];
  [editor editorTestAwaitInput:@"#project-title" value:@"Native migration draft" focused:YES];
  [editor editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"3\"]').click();"];command(editor,@{@"type":@"snapshot"});
  [editor editorTestScript:@"(()=>{const field=document.getElementById('field-alpha');field.focus();field.select();})();"];[editor editorTestType:@".4"];
  [editor editorTestAwaitInput:@"#field-alpha" value:@".4" focused:YES];
  // Focus Run without blurring through a workbench command: trusted native
  // Return activates its standard button behavior and emits the real event.
  [editor editorTestScript:@"document.getElementById('run-preview').focus();"];
  [editor clipTestAwait:@"document.activeElement.id==='run-preview'"];[editor gltfTestReturn];
  waitUntil(^{return completed==1||failure!=nil;},8,"Run event to native freeze/snapshot/thaw deadlocked");
  require(!failure&&!rejected&&requests==1&&[captured[@"title"] isEqual:@"Native migration draft"],"Run did not capture the actual valid focused draft");
  NSMutableDictionary* expectedScene=[original[@"scene"] mutableCopy];NSMutableArray* expectedObjects=[expectedScene[@"objects"] mutableCopy];NSMutableDictionary* expectedLayer=[expectedObjects[1] mutableCopy];expectedLayer[@"alpha"]=@.4;expectedObjects[1]=expectedLayer;expectedScene[@"objects"]=expectedObjects;
  require([captured[@"scene"] isEqual:expectedScene]&&captured[@"resourceOverrides"]==nil,"Run changed source wrappers or lost the actual focused material-layer edit");
  NSDictionary* valid=captured;command(editor,@{@"type":@"undo"});command(editor,@{@"type":@"undo"});require([command(editor,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Run created its own history revision");command(editor,@{@"type":@"redo"});command(editor,@{@"type":@"redo"});require([command(editor,@{@"type":@"snapshot"})[@"document"] isEqual:valid],"Run lost the authored history revision");
  [editor editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"1\"]').click();"];
  command(editor,@{@"type":@"snapshot"});
  [editor editorTestScript:@"document.getElementById('timeline-toggle').click();"];command(editor,@{@"type":@"snapshot"});
  [editor editorTestScript:@"(()=>{const key=document.querySelector('.timeline-key[data-property=\"origin\"][data-channel=\"0\"][data-frame=\"0\"]');key.click();})();"];command(editor,@{@"type":@"snapshot"});
  [editor editorTestScript:@"(()=>{const field=document.getElementById('timeline-key-value');field.focus();field.select();})();"];
  [editor editorTestType:@"-"];[editor editorTestScript:@"document.getElementById('run-preview').focus();"];
  [editor clipTestAwait:@"document.activeElement.id==='run-preview'"];[editor gltfTestKey:@" " code:49];
  waitUntil(^{return completed==2||failure!=nil;},8,"Invalid Run draft did not finish native thaw");
  require(!failure&&rejected&&captured==nil&&requests==2,"Run accepted invalid visible input or failed to report its rejection");
  [editor editorTestScript:@"document.getElementById('timeline-revert').click();"];
  require([command(editor,@{@"type":@"snapshot"})[@"document"] isEqual:valid],"Invalid Run changed canonical content");migrationVerifyQuiet(editor);
  require(stages==0&&[previewFileBytes(projectRoot) isEqual:sourceBytes],"Native migration staged resource blobs or changed project files");
  NSString* editorOrigin=editor.origin;
  previewClose(editor,0,runtime);[window close];editor.onEditorPreview=nil;
  NSString* captureRoot=[cache stringByAppendingPathComponent:@"MigrationCaptured"];
  require([NSFileManager.defaultManager copyItemAtPath:projectRoot toPath:captureRoot error:&error],error.localizedDescription.UTF8String ?: "Cannot materialize owned captured fixture");
  NSData* scene=[NSJSONSerialization dataWithJSONObject:valid[@"scene"] options:0 error:&error];
  require(scene&&[scene writeToFile:[captureRoot stringByAppendingPathComponent:@"scene.json"] options:NSDataWritingAtomic error:&error],"Cannot write actual captured scene revision");
  migrationVerifyPlayback(runtime,captureRoot,previewRuntime,NO,.4,editorOrigin);
  migrationVerifyPlayback(runtime,projectRoot,mainRuntime,NO);migrationVerifyPlayback(runtime,packageRoot,mainRuntime,YES);
  require([previewFileBytes(projectRoot) isEqual:sourceBytes],"Playback changed original migration source files");
  require([NSFileManager.defaultManager removeItemAtPath:captureRoot error:&error],"Cannot remove released captured fixture");
  migrationVerifyMissingHandler(runtime,projectRoot,editorRuntime,[cache stringByAppendingPathComponent:@"MissingPreviewResources"]);
  fprintf(stderr,"Native migration: quiet authoring, trusted Return/Space Run, actual callback freeze/valid capture/invalid rejection/thaw, unchanged history/resources, five real script anchors in isolated preview and both Main exports passed\n");
}
