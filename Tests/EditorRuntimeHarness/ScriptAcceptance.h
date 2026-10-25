#pragma once

@interface DWWebPage (ScriptAcceptance)
- (BOOL)scriptTestHasEditorSession;
@end
@implementation DWWebPage (ScriptAcceptance)
- (BOOL)scriptTestHasEditorSession { return _resources&&_resources->state&&bool(_resources->state->editor); }
@end

static NSString* scriptContractWave() {
  return @"export function update(value){return Math.floor(engine.runtime*2)%2===0?{x:0,y:1,z:0}:{x:1,y:0,z:0};}";
}
static void scriptVerifyExpected(NSDictionary* original,NSDictionary* expected) {
  require([original[@"scene"][@"objects"] count]==1,"Native script contract source requires its one model layer");
  NSMutableDictionary* value=[original mutableCopy],*scene=[original[@"scene"] mutableCopy];NSMutableArray* objects=[scene[@"objects"] mutableCopy];
  NSMutableDictionary* layer=[objects[0] mutableCopy],*color=[layer[@"color"] mutableCopy];
  require([layer[@"id"] isEqual:@1]&&[color[@"value"] isEqual:@"0 1 0"]&&[color[@"future"][@"keep"] boolValue],"Native script fixture must retain its exact color base and future wrapper metadata");
  color[@"script"]=scriptContractWave();layer[@"color"]=color;objects[0]=layer;scene[@"objects"]=objects;value[@"scene"]=scene;
  require([expected isEqual:value],"Native script expected document must change only the exact known color-wave source");
}

static void verifyScriptContracts(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,NSString* resources,NSString* sourcePath,NSString* expectedPath) {
  NSDictionary* original=clipJSON(sourcePath),*expected=clipJSON(expectedPath);scriptVerifyExpected(original,expected);
  NSDictionary* blank=@{@"title":@"Native compile-only contracts",@"entry":@"scene.json",@"project":@{@"type":@"scene",@"file":@"scene.json"},@"scene":@{@"general":@{@"orthogonalprojection":@{@"width":@640,@"height":@360},@"clearenabled":@YES,@"clearcolor":@"0.05 0.05 0.08"},@"objects":@[]}};
  NSError* error=nil;__block NSError* failure=nil;__block NSUInteger stageRequests=0;
  DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":blank} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native script blank workbench creation failed");page.onError=^(NSError* value){failure=value;};
  configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});void(^resourceHandler)(NSDictionary*)=[page.onEditorResource copy];
  page.onEditorResource=^(NSDictionary* request){if([request[@"action"] isEqual:@"stage"])++stageRequests;resourceHandler(request);};NSWindow* window=fkHostWindow(page);
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native script blank workbench first frame timed out");require(!failure,"Native script blank workbench failed");
  require([page editorTestNativeViewIsAttached]&&[page scriptTestHasEditorSession],"Native script blank workbench must use its attached actual CEF Editor page");command(page,@{@"type":@"thaw"});
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:blank],"Native script workbench was not blank before compiler-only checks");
  NSDictionary* input=@{@"original":original,@"expected":expected};NSString* json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:input options:0 error:nil] encoding:NSUTF8StringEncoding];
  fprintf(stderr,"Native scripts phase=offline-compiler-and-standalone-history\n");
  [page editorTestScript:[NSString stringWithFormat:@"window.__scriptContracts={done:false};(async()=>{const input=%@;\n%s\n})().catch(error=>{window.__scriptContracts={done:true,error:String(error),stack:String(error.stack)};});",json,R"JS(
    // CEF ExecuteJavaScript has no module referrer; resolve against the page.
    const api=await import(new URL('./script-api.mjs',location.href).href),{SceneDocument}=await import(new URL('./document.mjs',location.href).href);
    const assert=(condition,message)=>{if(!condition)throw new Error(message);};
    delete globalThis.__ScriptMustNotRun;
    const probes=[
      'globalThis.__ScriptMustNotRun=true; export function update(value){return value;}',
      'export function update(value){throw new Error("Compile-only body must not run");}',
      'Function("globalThis.__ScriptMustNotRun=true")(); export function update(value){return value;}',
      'throw new Error("Compile-only top-level source must not run"); export function update(value){return value;}'
    ];
    const checks=[];
    for(const source of probes){
      const check=api.checkSceneScript(source);assert(check.ok,'Native checker rejected a valid execution probe: '+check.message);checks.push(check);
      const probe=new SceneDocument(input.original);api.prepareSceneScript(probe,{layerId:1,target:'color',type:'set',source});
      assert(!probe.canUndo&&!probe.dirty,'Preparing source changed standalone history');
      assert(!Object.hasOwn(globalThis,'__ScriptMustNotRun'),'Compilation executed supplied probe source');
    }
    const doc=new SceneDocument(input.original),badSource='export function update( {';let syntax;
    try{api.prepareSceneScript(doc,{layerId:1,target:'color',type:'set',source:badSource});throw new Error('Invalid script unexpectedly produced a proposal');}
    catch(error){
      assert(error.name==='SceneScriptSyntaxError','Syntax preparation did not surface its structured native error');
      assert(error.target==='color'&&error.layerId===1&&error.check?.ok===false&&error.line===error.check.line,'Native syntax diagnostic lost target, layer or line parity');
      syntax={name:error.name,message:error.message,line:error.line,target:error.target,layerId:error.layerId,check:error.check};
    }
    assert(!doc.canUndo&&!doc.dirty,'Rejected source changed standalone history');
    const source=input.expected.scene.objects[0].color.script,proposal=api.prepareSceneScript(doc,{layerId:1,target:'color',type:'set',source});
    assert(Object.isFrozen(proposal),'Checked source proposal is not immutable');api.applySceneScript(doc,proposal);
    assert(doc.canUndo&&doc.dirty,'Checked source application did not create one standalone revision');const authored=doc.snapshot();
    doc.undo();const undone=doc.snapshot();assert(!doc.canUndo&&doc.canRedo,'Script edit did not undo in one revision');
    doc.redo();const redone=doc.snapshot();assert(!doc.canRedo,'Script redo left an unexpected extra revision');
    let replayRejected=false;try{api.applySceneScript(doc,proposal);}catch{replayRejected=true;}assert(replayRejected,'Consumed source proposal could be replayed');
    doc.markSaved();assert(!doc.dirty,'Standalone source save acknowledgement remained dirty');
    const reparsed=new SceneDocument(JSON.parse(JSON.stringify(doc.snapshot()))).snapshot();
    assert(!Object.hasOwn(globalThis,'__ScriptMustNotRun'),'Source preparation or application executed supplied code');
    window.__scriptContracts={done:true,checks,syntax,authored,undone,redone,reparsed,probeExecuted:Object.hasOwn(globalThis,'__ScriptMustNotRun')};
  )JS"]];
  NSDictionary* result=[page clipTestAwait:@"window.__scriptContracts?.done&&window.__scriptContracts"][@"value"];
  if(result[@"error"])fprintf(stderr,"Native script contracts renderer error: %s\n",[result[@"stack"] UTF8String] ?: [result[@"error"] UTF8String]);
  require(result[@"error"]==nil,"Native compile-only/source-history assertions failed in actual CEF");
  require([result[@"checks"] count]==4&&![result[@"probeExecuted"] boolValue],"Native source execution probes were not checked without running");
  NSDictionary* syntax=result[@"syntax"];
  require([syntax[@"name"] isEqual:@"SceneScriptSyntaxError"]&&[syntax[@"target"] isEqual:@"color"]&&[syntax[@"layerId"] isEqual:@1]&&syntax[@"line"]!=nil&&[syntax[@"message"] length]>0,"Native script syntax error did not retain its structured target and native line diagnostic");
  require([result[@"authored"] isEqual:expected]&&[result[@"undone"] isEqual:original]&&[result[@"redone"] isEqual:expected]&&[result[@"reparsed"] isEqual:expected],"Native standalone script proposal, history or serialization did not preserve the exact independent documents");
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:blank],"Standalone script checks or source edits changed the live blank workbench");
  [page clipTestAwait:@"document.querySelector('#canvas canvas')&&document.querySelectorAll('#layers button[data-layer-id]').length===0&&!Object.hasOwn(globalThis,'__ScriptMustNotRun')"];
  NSArray* staged=[NSFileManager.defaultManager contentsOfDirectoryAtPath:resources error:&error];require(staged!=nil,error.localizedDescription.UTF8String ?: "Cannot inspect native script resource store");
  require(stageRequests==0&&staged.count==0,"Compile-only standalone script operations requested or staged native resources");
  require([clipJSON(sourcePath) isEqual:original]&&[clipJSON(expectedPath) isEqual:expected],"Native script checks modified source contract fixture files");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native script blank editor close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native script blank editor resources were not released");[window close];
  fprintf(stderr,"Native scripts: actual offline compiler without probe execution, structured syntax diagnostics, exact standalone proposals/history/reparse and unchanged blank workbench passed\n");
}

static void verifyScriptExport(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,BOOL package) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json" representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native script Main page creation failed");require(![page scriptTestHasEditorSession],"Main script playback unexpectedly acquired an Editor bridge session");
  page.onError=^(NSError* value){failure=value;};[page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native script Main first frame timed out");require(!failure,"Native script Main rendering failed");
  __block NSUInteger phase=0,samples=0;
  waitUntil(^{NSDictionary* pixels=eventPixels(page);if([pixels[@"count"][0] unsignedLongValue]<100||[pixels[@"count"][1] unsignedLongValue]<100)return NO;
    require(std::abs([pixels[@"x"][0] doubleValue]-284.5)<1.5&&std::abs([pixels[@"x"][1] doubleValue]-354.5)<1.5,"Native script Main moved horizontal model placement");
    require(std::abs([pixels[@"y"][0] doubleValue]-179.5)<1.5&&std::abs([pixels[@"y"][1] doubleValue]-179.5)<1.5,"Native script Main moved a stationary model mesh");
    const BOOL green=[pixels[@"green"][0] unsignedLongValue]>100&&[pixels[@"green"][1] unsignedLongValue]>100,red=[pixels[@"red"][0] unsignedLongValue]>100&&[pixels[@"red"][1] unsignedLongValue]>100;
    if((phase==0&&green)||(phase==1&&red)||(phase==2&&green))++phase;++samples;return BOOL(phase==3);
  },2,"Native script Main did not render actual green/red/green color-wave pixels in both meshes");require(!failure,"Native script Main reported an error");
  require(![page scriptTestHasEditorSession],"Main script runtime acquired an Editor bridge session during playback");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native script Main close timed out");
  require(!failure&&page.closed&&runtime.activePageCount==0,"Native script Main resources were not released");
  fprintf(stderr,"Main scripts %s: actual green/red/green wave pixels, fixed two-mesh positions, no Editor session and full release (%lu samples) passed\n",package?"PKG":"loose",static_cast<unsigned long>(samples));
}
