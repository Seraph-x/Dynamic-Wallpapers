// Test-only local bind editing with real AppKit input and actual staged MDL bytes.
static void verifyRestWorkbench(DWWebRuntime* runtime,NSString* projectRoot,NSString* runtimeRoot,NSString* resources) {
  NSData* sceneData=[NSData dataWithContentsOfFile:[projectRoot stringByAppendingPathComponent:@"scene.json"]];
  NSData* projectData=[NSData dataWithContentsOfFile:[projectRoot stringByAppendingPathComponent:@"project.json"]];
  require(sceneData!=nil&&projectData!=nil,"Native rest source fixture missing");
  NSDictionary* original=@{@"title":@"Native rest",@"entry":@"scene.json",@"scene":[NSJSONSerialization JSONObjectWithData:sceneData options:0 error:nil],@"project":[NSJSONSerialization JSONObjectWithData:projectData options:0 error:nil]};
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:projectRoot runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native rest workbench creation failed");
  page.onError=^(NSError* value){failure=value;};configureResources(page,resources,projectRoot,^(NSError* value){failure=value;});
  NSWindow* window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1180,760) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;page.view.frame=window.contentView.bounds;[window.contentView addSubview:page.view];[window makeKeyAndOrderFront:nil];
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native rest first frame timed out");require(!failure,"Native rest workbench failed");
  command(page,@{@"type":@"thaw"});[page editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"1\"]').click();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"document.getElementById('model-workspace').click();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"document.querySelector('#model-bones button[data-bone=\"2\"]').click();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"document.getElementById('model-rest-details').open=true;const input=document.getElementById('model-rest-tx');input.scrollIntoView({block:'center'});input.focus();input.select();"];
  [page editorTestAwaitInput:@"#model-rest-tx" value:@"35" focused:YES];
  [page editorTestType:@"45"];[page editorTestAwaitInput:@"#model-rest-tx" value:@"45"];
  NSDictionary* frozen=command(page,@{@"type":@"freeze"}),*document=frozen[@"document"];
  NSString* modelPath=@"models/editor/rig.mdl",*version=document[@"resourceOverrides"][modelPath];
  require(version.length==64&&[frozen[@"dirty"] boolValue],"Native rest focused input was not published before freeze");
  NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:version]];
  require(bytes!=nil&&[resourceHash(bytes) isEqual:version],"Native rest MDL hash mismatch");
  const char rightName[]="Right";NSData* name=[NSData dataWithBytes:rightName length:sizeof(rightName)];
  const NSRange found=[bytes rangeOfData:name options:0 range:NSMakeRange(0,bytes.length)];
  require(found.location!=NSNotFound,"Native rest bone record missing");
  const NSUInteger bindXOffset=found.location+name.length+12+12*sizeof(float);
  require(bindXOffset+sizeof(float)<=bytes.length,"Native rest matrix offset out of bounds");
  float bindX=0;[bytes getBytes:&bindX range:NSMakeRange(bindXOffset,sizeof(bindX))];require(bindX==45,"Native typed rest value did not reach actual bind matrix");
  command(page,@{@"type":@"mark-saved",@"document":document});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native rest save acknowledgement remained dirty");
  command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native rest undo was not one complete revision");
  command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:document],"Native rest redo lost the authored resource");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native rest editor close timed out");require(!failure,"Native rest close failed");[window close];
  fprintf(stderr,"Native rest: actual focused keyboard, bind matrix/hash, freeze/save and one-step history passed\n");
}
