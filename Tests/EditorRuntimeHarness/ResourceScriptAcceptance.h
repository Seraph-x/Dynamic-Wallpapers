#pragma once

static NSString* resourceScriptJSON(id value) {
  NSError* error=nil;NSData* data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed|NSJSONWritingWithoutEscapingSlashes error:&error];
  require(data!=nil,error.localizedDescription.UTF8String ?: "Cannot encode resource acceptance data");
  return [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
}
static void resourceScriptWrite(NSString* file,NSData* data) {
  NSError* error=nil;
  require(data!=nil&&[NSFileManager.defaultManager createDirectoryAtPath:file.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error]&&[data writeToFile:file options:NSDataWritingAtomic error:&error],error.localizedDescription.UTF8String ?: "Cannot write owned resource acceptance file");
}
static void resourceScriptSelect(DWWebPage* page,NSDictionary* target) {
  NSString* key=[@"resource:" stringByAppendingString:resourceScriptJSON(@[target[@"path"],target[@"anchor"]])];
  [page editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"1\"]').click();"];
  command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"document.getElementById('script-workspace').click();"];
  [page clipTestAwait:@"!document.getElementById('script-panel').hidden&&!document.getElementById('script-target').disabled"];
  [page editorTestScript:[NSString stringWithFormat:@"(()=>{const key=%@,target=document.getElementById('script-target');if(![...target.options].some(option=>option.value===key))throw Error('Missing resource source target');target.value=key;target.dispatchEvent(new Event('change',{bubbles:true}));})();",resourceScriptJSON(key)]];
  command(page,@{@"type":@"snapshot"});scriptWorkspaceInstallInspection(page);
  [page clipTestAwait:@"!document.getElementById('script-check').disabled"];
}
static DWWebPage* resourceScriptEditor(DWWebRuntime* runtime,NSString* root,NSString* editorRuntime,NSDictionary* document,NSString* blobs,NSWindow** host) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:root runtimeRoot:editorRuntime configuration:@{@"language":@"en",@"document":document} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Cannot create native resource Script workbench");
  page.onError=^(NSError* value){failure=value;};configureResources(page,blobs,root,^(NSError* value){failure=value;});
  *host=fkHostWindow(page);[page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native resource Script first frame timed out");
  require(!failure&&[page editorTestNativeViewIsAttached],"Native resource Script CEF view failed or detached");command(page,@{@"type":@"thaw"});
  return page;
}
static BOOL resourceScriptPixels(DWWebPage* page,NSString* sink) {
  CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;if(!image)return NO;
  NSData* data=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));require(data!=nil,"Cannot read native resource pixels");
  const auto* bytes=static_cast<const UInt8*>(data.bytes);const size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),rowBytes=CGImageGetBytesPerRow(image);size_t count=0;
  for(size_t y=0;y<height;++y)for(size_t x=0;x<width;++x){const size_t at=y*rowBytes+x*4;
    const bool blue=bytes[at]>180&&bytes[at+1]<50&&bytes[at+2]<50;
    const bool dim=bytes[at]>70&&bytes[at]<135&&bytes[at+1]>70&&bytes[at+1]<135&&bytes[at+2]>70&&bytes[at+2]<135;
    const bool white=bytes[at]>180&&bytes[at+1]>180&&bytes[at+2]>180;
    if([sink isEqual:@"effect"]?blue:[sink isEqual:@"child-override"]?dim:white)++count;
  }
  return count>100;
}
static void resourceScriptPlayback(DWWebRuntime* runtime,NSString* root,NSString* runtimeRoot,NSString* sink,BOOL package) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:root runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(320,180) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Cannot create resource playback");require(![page scriptTestHasEditorSession],"Resource playback acquired Editor authoring APIs");
  page.onError=^(NSError* value){failure=value;};require([page setOutputGain:0 error:&error],"Cannot mute resource playback");[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Native resource playback first frame timed out");require(!failure,"Native resource playback failed");
  waitUntil(^{return resourceScriptPixels(page,sink);},5,"Native resource script did not produce its independently expected GPU pixels");
  require([[page previewTestValue:@"globalThis.__resourceAuthoringMustNotRun===true&&typeof globalThis.__dynamicWallpaperEditor==='undefined'"] boolValue],"Native resource source did not execute independently of Editor");
  if([sink isEqual:@"emitter-rate"]){runFor(.5);NSDictionary* stats=[page previewTestValue:@"globalThis.__particleStats()"];
    require([stats[@"systems"][0][@"live"] unsignedIntegerValue]>20,"Authored emitter script did not advance the actual particle pool");}
  previewClose(page,0,runtime);
}
static void resourceScriptDiagnostics(DWWebRuntime* runtime,DWWebPage* editor,NSDictionary* sourceFiles,NSDictionary* target,NSString* cache,NSString* previewRuntime) {
  NSString* root=[cache stringByAppendingPathComponent:@"DiagnosticCapture"],*path=target[@"path"];
  NSString* comment=[@"雪😀" stringByPaddingToLength:9000 withString:@"雪😀" startingAtIndex:0];
  NSString* source=[NSString stringWithFormat:@"// %@\r\nexport function update(value){throw new Error('NativeResourceOrigin');}",comment];
  NSString* raw=[[NSString alloc]initWithData:sourceFiles[path] encoding:NSUTF8StringEncoding];
  NSData* bytes=[[raw stringByReplacingOccurrencesOfString:resourceScriptJSON(target[@"originalSource"]) withString:resourceScriptJSON(source)] dataUsingEncoding:NSUTF8StringEncoding];
  for(NSString* name in sourceFiles)resourceScriptWrite([root stringByAppendingPathComponent:name],[name isEqual:path]?bytes:sourceFiles[name]);
  NSError* error=nil;__block NSError* failure=nil;__block NSDictionary* received=nil;
  DWWebPage* preview=[runtime scenePageWithProjectRoot:root runtimeRoot:previewRuntime entry:@"scene.json" representation:@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(320,180) scale:1 error:&error];
  require(preview!=nil,error.localizedDescription.UTF8String ?: "Cannot create actual resource diagnostics preview");preview.onError=^(NSError* value){failure=value;};
  preview.onSceneScriptIssue=^(NSDictionary* issue){if([issue[@"layerId"] isEqual:@1])received=issue;};require([preview setOutputGain:0 error:&error],"Cannot mute actual resource diagnostics preview");[preview start];
  waitUntil(^{return BOOL(failure!=nil||([received[@"count"] isEqual:@3]&&preview.ready));},20,"Actual fragmented native resource issue did not arrive");
  require(!failure&&received.count==8&&[received[@"message"] isEqual:@"NativeResourceOrigin"]&&[received[@"phase"] isEqual:@"update"]&&[received[@"line"] isEqual:@2],"Actual native resource issue lost phase/count/location");
  NSDictionary* descriptor=received[@"source"];NSMutableArray* pointer=[target[@"anchor"] mutableCopy];[pointer addObject:@"script"];
  require(descriptor.count==5&&[descriptor[@"kind"] isEqual:@"resource"]&&[descriptor[@"path"] isEqual:path]&&[descriptor[@"sha256"] isEqual:resourceHash(bytes)]&&[descriptor[@"pointer"] isEqual:pointer]&&[descriptor[@"text"] isEqual:source],"Actual fragmented resource descriptor lost original bytes, literal pointer or complete Unicode source");
  NSDictionary* capture=command(editor,@{@"type":@"snapshot"});
  NSDictionary* link=@{@"documentIdentity":capture[@"documentIdentity"],@"layerId":received[@"layerId"],@"target":received[@"target"],@"path":pointer,@"source":source,@"line":received[@"line"],@"registered":@YES,@"resource":descriptor};
  NSDictionary* reply=command(editor,@{@"type":@"reveal-script",@"link":link});require([reply[@"navigation"][@"kind"] isEqual:@"captured"]&&[reply[@"navigation"][@"reason"] isEqual:@"source"],"Native resource issue guessed current source despite a different resource digest");
  [editor clipTestAwait:@"Boolean(document.getElementById('script-captured-dialog').open&&document.querySelector('#script-captured-source .cm-content'))"];
  NSDictionary* shown=[editor previewTestValue:@"(()=>{const {EditorView,EditorState}=window.__codeAcceptanceAPI,view=EditorView.findFromDOM(document.querySelector('#script-captured-source .cm-content'));return {source:view.state.sliceDoc(),readOnly:view.state.facet(EditorState.readOnly)};})()"];
  require([shown[@"readOnly"] boolValue]&&[shown[@"source"] isEqual:[source stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]],"Native captured resource view truncated or changed independently compiled source");
  [editor editorTestScript:@"document.getElementById('script-captured-close').click();"];previewClose(preview,1,runtime);
  fprintf(stderr,"Native resource diagnostics: actual >8192-byte Unicode source fragments, exact original digest/pointer/count/line and read-only captured navigation passed\n");
}
static void verifyResourceScriptWorkspace(DWWebRuntime* runtime,NSString* editorRuntime,NSString* fixture,NSString* previewRuntime,NSString* mainRuntime,NSString* cache) {
  NSDictionary* target=clipJSON([fixture stringByAppendingPathComponent:@"target.json"]),*original=clipJSON([fixture stringByAppendingPathComponent:@"source-document.json"]),*browserExpected=clipJSON([fixture stringByAppendingPathComponent:@"saved-document.json"]);
  NSString* sourceRoot=[fixture stringByAppendingPathComponent:@"Source"],*path=target[@"path"],*sink=target[@"sink"],*blobs=[cache stringByAppendingPathComponent:@"ResourceBlobs"];
  NSDictionary* sourceFiles=previewFileBytes(sourceRoot);NSData* originalBytes=sourceFiles[path];
  NSString* raw=[[NSString alloc]initWithData:originalBytes encoding:NSUTF8StringEncoding];
  NSString* expectedText=[raw stringByReplacingOccurrencesOfString:resourceScriptJSON(target[@"originalSource"]) withString:resourceScriptJSON(target[@"editedSource"])];
  NSData* expectedBytes=[expectedText dataUsingEncoding:NSUTF8StringEncoding];
  require(![expectedBytes isEqualToData:originalBytes]&&[expectedBytes isEqualToData:[NSData dataWithContentsOfFile:[fixture stringByAppendingPathComponent:@"expected-resource.bin"]]],"Native independent span-only resource oracle differs from browser output");
  require([resourceHash(expectedBytes) isEqual:target[@"expectedDigest"]],"Native resource oracle hash differs");
  NSMutableDictionary* expectedDocument=[original mutableCopy],*expectedOverrides=[original[@"resourceOverrides"] mutableCopy] ?: [NSMutableDictionary dictionary];
  expectedOverrides[path]=resourceHash(expectedBytes);expectedDocument[@"resourceOverrides"]=expectedOverrides;
  require([browserExpected isEqual:expectedDocument],"Browser resource snapshot changed fields outside the independently expected override");
  NSWindow* window=nil;DWWebPage* page=resourceScriptEditor(runtime,sourceRoot,editorRuntime,original,blobs,&window);resourceScriptSelect(page,target);
  scriptWorkspaceAwaitSource(page,[target[@"originalSource"] stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]);
  scriptWorkspaceType(page,target[@"editedSource"]);
  NSDictionary* frozen=command(page,@{@"type":@"freeze"}),*saved=frozen[@"document"];
  require([frozen[@"dirty"] boolValue]&&[saved isEqual:expectedDocument],"Focused native resource input did not commit exact source/hash before freeze");
  require(scriptWorkspaceReadOnly(page),"Frozen resource CodeMirror remains editable");
  NSString* version=saved[@"resourceOverrides"][path];NSData* staged=[NSData dataWithContentsOfFile:[blobs stringByAppendingPathComponent:version]];
  require([staged isEqualToData:expectedBytes],"Native resource staging changed unrelated bytes or authored source");
  command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native resource undo was not exactly one project revision");
  command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native resource redo lost its immutable version");
  command(page,@{@"type":@"mark-saved",@"document":saved});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native resource save acknowledgement remained dirty");command(page,@{@"type":@"thaw"});
  require([page previewTestValue:@"globalThis.__resourceAuthoringMustNotRun??null"]==NSNull.null,"Resource source executed in authoring mode");
  NSString* workspace=[cache stringByAppendingPathComponent:@"workspace.json"];resourceScriptWrite(workspace,[resourceScriptJSON(saved) dataUsingEncoding:NSUTF8StringEncoding]);
  NSDictionary* package=command(page,@{@"type":@"export-pkg",@"paths":sourceFiles.allKeys});NSData* packageBytes=[[NSData alloc]initWithBase64EncodedString:package[@"pkg"] options:0];require(packageBytes.length>0,"Native resource package export is empty");
  previewClose(page,0,runtime);[window close];
  page=resourceScriptEditor(runtime,sourceRoot,editorRuntime,clipJSON(workspace),blobs,&window);resourceScriptSelect(page,target);scriptWorkspaceAwaitSource(page,target[@"editedSource"]);
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:saved],"Native resource disk snapshot reopen lost its version/source");
  if([sink isEqual:@"effect"])resourceScriptDiagnostics(runtime,page,sourceFiles,target,cache,previewRuntime);
  previewClose(page,0,runtime);[window close];
  require([previewFileBytes(sourceRoot) isEqual:sourceFiles],"Native resource editing changed original source resources");
  NSString* loose=[cache stringByAppendingPathComponent:@"Loose"],*packageRoot=[cache stringByAppendingPathComponent:@"Package"];
  for(NSString* name in sourceFiles)resourceScriptWrite([loose stringByAppendingPathComponent:name],[name isEqual:path]?staged:sourceFiles[name]);
  resourceScriptWrite([loose stringByAppendingPathComponent:@"scene.json"],[resourceScriptJSON(saved[@"scene"]) dataUsingEncoding:NSUTF8StringEncoding]);
  NSMutableDictionary* metadata=[saved[@"project"] mutableCopy];metadata[@"file"]=@"scene.json";resourceScriptWrite([loose stringByAppendingPathComponent:@"project.json"],[resourceScriptJSON(metadata) dataUsingEncoding:NSUTF8StringEncoding]);
  metadata[@"file"]=@"scene.pkg";resourceScriptWrite([packageRoot stringByAppendingPathComponent:@"project.json"],[resourceScriptJSON(metadata) dataUsingEncoding:NSUTF8StringEncoding]);resourceScriptWrite([packageRoot stringByAppendingPathComponent:@"scene.pkg"],packageBytes);
  resourceScriptPlayback(runtime,loose,previewRuntime,sink,NO);resourceScriptPlayback(runtime,packageRoot,previewRuntime,sink,YES);
  resourceScriptPlayback(runtime,loose,mainRuntime,sink,NO);resourceScriptPlayback(runtime,packageRoot,mainRuntime,sink,YES);
  require([previewFileBytes(sourceRoot) isEqual:sourceFiles],"Native playback changed original resource hashes");
  fprintf(stderr,"Native resource Script %s: actual keyboard/freeze, exact staged bytes, undo/redo, saved reopen, independent preview and Main loose/PKG pixels and complete release passed\n",sink.UTF8String);
}
