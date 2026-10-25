#pragma once

static NSString* codeToolsGreenSource() {
  return @"// code tools — 雪\nexport function update(value){\n  return {x:0,y:1,z:0};\n}\n// shade: GREEN GREEN\n";
}
static NSString* codeToolsRedSource() {
  return @"// code tools — 雪\nexport function update(value){\n  return {x:1,y:0,z:0};\n}\n// shade: RED RED\n";
}
static NSString* codeToolsInitSource() {
  return @"let initial;\n\nexport function init(value) {\n  initial = new Vec3(value);\n  return initial;\n}\n\nexport function update(value) {\n  return initial;\n}\n";
}
static NSDictionary* codeToolsExpected(NSDictionary* original) {
  NSMutableDictionary* value=[original mutableCopy],*scene=[original[@"scene"] mutableCopy];NSMutableArray* objects=[scene[@"objects"] mutableCopy];
  require(objects.count==3&&[objects[0][@"id"] isEqual:@1],"Code tools requires its independent migration fixture");
  NSMutableDictionary* layer=[objects[0] mutableCopy],*color=[layer[@"color"] mutableCopy];
  require([color[@"value"] isEqual:@"0 1 0"]&&[color[@"future"][@"keep"] boolValue],"Code tools lost the color base or unrelated wrapper");
  color[@"script"]=codeToolsRedSource();layer[@"color"]=color;objects[0]=layer;scene[@"objects"]=objects;value[@"scene"]=scene;return value;
}
static void codeToolsRedo(DWWebPage* page) {
  [page editorTestScript:@"document.querySelector('#script-source .cm-content').focus();"];
  [page clipTestAwait:@"document.activeElement===document.querySelector('#script-source .cm-content')"];
  [page codeTestChord:@"z" code:6 modifiers:NSEventModifierFlagCommand|NSEventModifierFlagShift];
}
static void codeToolsUndo(DWWebPage* page) {
  [page editorTestScript:@"document.querySelector('#script-source .cm-content').focus();"];
  [page clipTestAwait:@"document.activeElement===document.querySelector('#script-source .cm-content')"];
  [page codeTestShortcut:@"z" code:6];
}
static void codeToolsReplaceAll(DWWebPage* page,NSString* find,NSString* replace) {
  [page editorTestScript:@"(()=>{const input=document.querySelector('.cm-search input[name=search]');input.focus();input.select();})();"];
  [page clipTestAwait:@"(()=>{const input=document.querySelector('.cm-search input[name=search]');return document.activeElement===input&&input.selectionStart===0&&input.selectionEnd===input.value.length;})()"];
  fprintf(stderr,"Native code tools search=find-input %s\n",find.UTF8String);
  [page editorTestType:find];[page editorTestAwaitInput:@".cm-search input[name=search]" value:find focused:YES];
  [page editorTestScript:@"(()=>{const input=document.querySelector('.cm-search input[name=replace]');input.focus();input.select();})();"];
  [page clipTestAwait:@"(()=>{const input=document.querySelector('.cm-search input[name=replace]');return document.activeElement===input&&input.selectionStart===0&&input.selectionEnd===input.value.length;})()"];
  fprintf(stderr,"Native code tools search=replace-input %s\n",replace.UTF8String);
  [page editorTestType:replace];[page editorTestAwaitInput:@".cm-search input[name=replace]" value:replace focused:YES];
  [page editorTestScript:@"document.querySelector('.cm-search button[name=replaceAll]').focus();"];
  [page clipTestAwait:@"document.activeElement===document.querySelector('.cm-search button[name=replaceAll]')"];
  [page gltfTestReturn];
}
static void verifyCodeTools(DWWebRuntime* runtime,NSString* projectRoot,NSString* editorRuntime,NSString* cache,NSString* sourcePath,NSString* expectedPath) {
  NSDictionary* original=clipJSON(sourcePath),*expected=codeToolsExpected(original);require([clipJSON(expectedPath) isEqual:expected],"Code tools browser output differs from independent native source bytes");
  NSDictionary* originalFiles=previewFileBytes(projectRoot);NSString* resources=[cache stringByAppendingPathComponent:@"CodeToolsResources"];
  NSError* error=nil;__block NSError* failure=nil;__block NSUInteger stages=0;
  DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:editorRuntime configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native CodeMirror creation failed");page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});
  void(^resourceHandler)(NSDictionary*)=[page.onEditorResource copy];page.onEditorResource=^(NSDictionary* event){if([event[@"action"] isEqual:@"stage"])++stages;resourceHandler(event);};
  NSWindow* window=fkHostWindow(page);[page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native CodeMirror first frame timed out");require(!failure&&[page editorTestNativeViewIsAttached],"Code tools must use actual attached CEF input");command(page,@{@"type":@"thaw"});
  [page editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"1\"]').click();document.getElementById('script-workspace').click();"];
  [page clipTestAwait:@"document.getElementById('script-target').options.length>0"];
  [page editorTestScript:@"(()=>{const target=document.getElementById('script-target');target.value='color';target.dispatchEvent(new Event('change',{bubbles:true}));})();"];
  scriptWorkspaceInstallInspection(page);scriptWorkspaceAwaitSource(page,original[@"scene"][@"objects"][0][@"color"][@"script"]);
  [page clipTestAwait:@"document.querySelector('#script-source').tagName==='DIV'&&!document.querySelector('#script-source textarea')&&document.querySelector('#script-source .cm-content').getAttribute('role')==='textbox'"];
  fprintf(stderr,"Native code tools phase=template-freeze-cancel\n");
  [page editorTestScript:@"(()=>{const select=document.getElementById('script-template');select.value='init';select.dispatchEvent(new Event('change',{bubbles:true}));document.getElementById('script-use-template').click();})();"];
  [page clipTestAwait:@"document.getElementById('script-template-confirm').open"];
  NSDictionary* choiceFrozen=command(page,@{@"type":@"freeze"});require([choiceFrozen[@"document"] isEqual:original]&&[choiceFrozen[@"dirty"] boolValue],"Unresolved native template choice must retain a dirty unchanged document");
  __block BOOL choiceDone=NO;__block NSDictionary* choiceReply=nil;__block NSError* choiceError=nil;
  [page requestEditorCommand:@{@"type":@"snapshot"} completion:^(NSDictionary* value,NSError* error){choiceReply=value;choiceError=error;choiceDone=YES;}];
  waitUntil(^{return choiceDone;},8,"Native template snapshot barrier did not respond");require(!choiceError&&[choiceReply[@"error"] length]>0,"Unresolved native template choice must explicitly reject capture");
  command(page,@{@"type":@"thaw"});[page editorTestScript:@"document.getElementById('script-template-cancel').focus();"];[page clipTestAwait:@"document.activeElement===document.getElementById('script-template-cancel')"];[page gltfTestReturn];
  [page clipTestAwait:@"!document.getElementById('script-template-confirm').open"];
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native Cancel left a stale template barrier after freeze/thaw");
  fprintf(stderr,"Native code tools phase=completion\n");
  scriptWorkspaceType(page,@"engine.ru");[page editorTestScript:@"document.getElementById('script-complete').click();"];
  // The pinned completion keymap deliberately ignores Enter during its first
  // 75 ms. Observe the selected popup, then poll that actual interaction window.
  [page clipTestAwait:@"(()=>{const selected=document.querySelector('.cm-tooltip-autocomplete [aria-selected=true] .cm-completionLabel');if(selected?.textContent!=='runtime')return false;if(typeof window.__codeCompletionVisibleAt!=='number')window.__codeCompletionVisibleAt=performance.now();return performance.now()-window.__codeCompletionVisibleAt>=75;})()"];
  [page gltfTestReturn];scriptWorkspaceAwaitSource(page,@"engine.runtime");codeToolsUndo(page);scriptWorkspaceAwaitSource(page,@"engine.ru");codeToolsRedo(page);scriptWorkspaceAwaitSource(page,@"engine.runtime");
  fprintf(stderr,"Native code tools phase=template-confirmation-and-history\n");
  [page editorTestScript:@"(()=>{const select=document.getElementById('script-template');select.value='init';select.dispatchEvent(new Event('change',{bubbles:true}));document.getElementById('script-use-template').click();})();"];
  [page clipTestAwait:@"document.getElementById('script-template-confirm').open"];
  [page editorTestScript:@"document.getElementById('script-template-cancel').focus();"];[page clipTestAwait:@"document.activeElement===document.getElementById('script-template-cancel')"];[page gltfTestReturn];scriptWorkspaceAwaitSource(page,@"engine.runtime");
  [page editorTestScript:@"document.getElementById('script-use-template').click();"];
  [page clipTestAwait:@"document.getElementById('script-template-confirm').open"];
  [page editorTestScript:@"document.getElementById('script-template-replace').focus();"];[page clipTestAwait:@"document.activeElement===document.getElementById('script-template-replace')"];[page gltfTestReturn];scriptWorkspaceAwaitSource(page,codeToolsInitSource());
  [page clipTestAwait:@"document.querySelectorAll('#script-source .cm-line span').length>0"];
  codeToolsUndo(page);scriptWorkspaceAwaitSource(page,@"engine.runtime");codeToolsRedo(page);scriptWorkspaceAwaitSource(page,codeToolsInitSource());
  fprintf(stderr,"Native code tools phase=actual-search-replace-and-freeze\n");
  scriptWorkspaceType(page,codeToolsGreenSource());[page editorTestScript:@"document.getElementById('script-find').click();"];
  [page clipTestAwait:@"Boolean(document.querySelector('.cm-search input[name=search]'))"];
  codeToolsReplaceAll(page,@"GREEN",@"RED");codeToolsReplaceAll(page,@"x:0,y:1",@"x:1,y:0");scriptWorkspaceAwaitSource(page,codeToolsRedSource());
  [page editorTestScript:@"document.querySelector('.cm-search button[name=close]').focus();"];[page clipTestAwait:@"document.activeElement===document.querySelector('.cm-search button[name=close]')"];[page gltfTestReturn];
  codeToolsUndo(page);scriptWorkspaceAwaitSource(page,[codeToolsGreenSource() stringByReplacingOccurrencesOfString:@"GREEN" withString:@"RED"]);codeToolsRedo(page);scriptWorkspaceAwaitSource(page,codeToolsRedSource());
  [page editorTestScript:@"document.getElementById('script-find').click();"];
  [page clipTestAwait:@"Boolean(document.querySelector('.cm-search input[name=search]'))"];
  [page editorTestScript:@"document.querySelector('.cm-search input[name=replace]').focus();"];
  [page clipTestAwait:@"document.activeElement===document.querySelector('.cm-search input[name=replace]')"];
  NSDictionary* frozen=command(page,@{@"type":@"freeze"});require([frozen[@"document"] isEqual:expected]&&[frozen[@"dirty"] boolValue]&&scriptWorkspaceReadOnly(page),"Focused search/native freeze lost actual authored source or editor locks");
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:expected],"Code tools snapshot differs from captured exact source");command(page,@{@"type":@"thaw"});
  command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Code tools draft edits created more than one canonical history step");
  command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:expected],"Code tools canonical redo lost exact edited source");
  command(page,@{@"type":@"mark-saved",@"document":expected});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Code tools save acknowledgement remained dirty");
  migrationVerifyQuiet(page);require(stages==0&&[previewFileBytes(projectRoot) isEqual:originalFiles],"Code tools executed imported source, staged model resources or modified fixture files");
  previewClose(page,0,runtime);[window close];fprintf(stderr,"Native CodeMirror: trusted input/completion/templates/local undo/search Replace all/focused freeze, exact canonical history/save, quiet workbench and full release passed\n");
}
