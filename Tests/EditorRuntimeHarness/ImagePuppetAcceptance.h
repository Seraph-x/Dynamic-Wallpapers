// Test-only image authoring and playback through the actual Editor/Main CEF pages.
@interface DWWebPage (BrushAcceptance)
- (void)editorTestPaintCorner;
@end
@implementation DWWebPage (BrushAcceptance)
- (void)editorTestPaintCorner {
  __block NSDictionary* point=nil;__block NSError* failure=nil;NSString* identifier=NSUUID.UUID.UUIDString;
  _editorCompletions[identifier]=^(NSDictionary* reply,NSError* error){point=reply;failure=error;};
  _editorDeadlines[identifier]=@(NSProcessInfo.processInfo.systemUptime+5);
  NSDictionary* envelope=@{@"type":@"reply",@"id":identifier,@"session":@(_resources->state->editor->session.c_str()),@"generation":@1};
  NSString* json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil] encoding:NSUTF8StringEncoding];
  [self editorTestScript:[NSString stringWithFormat:@"(()=>{const envelope=%@,canvas=document.getElementById('model-weight-map');canvas.scrollIntoView({block:'center'});requestAnimationFrame(()=>{const r=canvas.getBoundingClientRect();envelope.payload={x:r.left+12*r.width/320,y:r.top+16*r.height/180};fetch('/__editor/event',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(envelope)});});})();",json]];
  waitUntil(^{return point!=nil||failure!=nil;},6,"Native brush map measurement timed out");require(!failure&&point!=nil,"Native brush coordinate acknowledgement failed");
  CefMouseEvent mouse;mouse.x=[point[@"x"] intValue];mouse.y=[point[@"y"] intValue];mouse.modifiers=0;
  auto host=_resources->state->browser->GetHost();host->SetFocus(true);host->SendMouseMoveEvent(mouse,false);
  host->SendMouseClickEvent(mouse,MBT_LEFT,false,1);host->SendMouseClickEvent(mouse,MBT_LEFT,true,1);
}
@end
static NSArray* imageQuadrants(DWWebPage* page) {
  CGImageRef image=(__bridge CGImageRef)page.view.layer.contents;
  if(!image)return @[];
  NSData* data=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
  require(data!=nil,"Image pixel read failed");
  const auto* bytes=static_cast<const UInt8*>(data.bytes);
  const size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),row=CGImageGetBytesPerRow(image);
  size_t count[4]={0,0,0,0};double xs[4]={0,0,0,0},ys[4]={0,0,0,0},minX[4]={1e9,1e9,1e9,1e9};
  for(size_t y=0;y<height;++y)for(size_t x=0;x<width;++x){
    const size_t p=y*row+x*4;const auto b=bytes[p],g=bytes[p+1],r=bytes[p+2];
    const int color=r>180&&g<70&&b<70?0:r<70&&g>180&&b<70?1:r<70&&g<70&&b>180?2:r>180&&g>180&&b<70?3:-1;
    if(color>=0){++count[color];xs[color]+=x;ys[color]+=y;minX[color]=std::min(minX[color],double(x));}
  }
  NSMutableArray* result=[NSMutableArray array];
  for(int i=0;i<4;++i)[result addObject:@[@(count[i]),@(count[i]?xs[i]/count[i]:0),@(count[i]?ys[i]/count[i]:0),@(count[i]?minX[i]:0)]];
  return result;
}
static void verifyImageExport(DWWebRuntime* runtime,NSString* root,NSString* runtimeRoot,BOOL package,BOOL animated,BOOL painted=NO) {
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime scenePageWithProjectRoot:root runtimeRoot:runtimeRoot entry:package?@"scene.pkg":@"scene.json"
    representation:package?@"package":@"loose" sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(640,360) scale:1 error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Image export page creation failed");
  page.onError=^(NSError* value){failure=value;};[page start];
  waitUntil(^{return page.ready||failure!=nil;},20,"Main image export first frame timed out");require(!failure,"Main image export failed");
  __block double low=1e9,high=-1e9;
  waitUntil(^{
    NSArray* q=imageQuadrants(page);if(q.count!=4)return NO;
    for(NSArray* color in q)if([color[0] unsignedLongValue]<200)return NO;
    for(int i=0;i<4;++i){
      const double x=[q[i][1] doubleValue],y=[q[i][2] doubleValue];
      require(std::abs(y-(i<2?169.5:189.5))<2,"Image mesh vertical placement or UV orientation changed");
      const double displacement=x-(i%2?339.5:299.5);
      require(displacement>=-2&&displacement<=(animated?22:2),"Image mesh horizontal placement changed");
      if(i&&!painted){const double expected=i%2?40:0;require(std::abs(x-[q[0][1] doubleValue]-expected)<2,"Image quadrants did not retain relative geometry");}
    }
    if(painted)require([q[0][3] doubleValue]>=279&&[q[0][3] doubleValue]<=283,"Painted image corner did not remain fixed while the root moved");
    const double delta=painted?[q[1][1] doubleValue]-339.5:[q[0][1] doubleValue]-299.5;low=std::min(low,delta);high=std::max(high,delta);
    return BOOL(!animated||(delta>4&&delta<16&&high-low>6));
  },3,"Main did not render image quadrants and known intermediate root motion");
  require(!failure,"Main image export reported an error");
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];
  waitUntil(^{return released;},7,"Image export close timed out");require(!failure,"Image export close failed");
  fprintf(stderr,"Main image %s: four-quadrant orientation, bind placement and %s %.2f..%.2f px passed\n",package?"PKG":"loose",painted?"painted corner and root motion":animated?"root motion":"original image",low,high);
}
static void verifyImageCreation(DWWebRuntime* runtime,NSString* root,NSString* runtimeRoot,NSString* resources,BOOL paint=NO) {
  NSData* sceneData=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"scene.json"]];
  NSData* projectData=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"project.json"]];
  require(sceneData!=nil&&projectData!=nil,"Native image source fixture missing");
  NSDictionary* scene=[NSJSONSerialization JSONObjectWithData:sceneData options:0 error:nil];
  NSDictionary* project=[NSJSONSerialization JSONObjectWithData:projectData options:0 error:nil];
  NSDictionary* original=@{@"title":@"Native image",@"entry":@"scene.json",@"scene":scene,@"project":project};
  NSError* error=nil;__block NSError* failure=nil;
  DWWebPage* page=[runtime editorPageWithProjectRoot:root runtimeRoot:runtimeRoot configuration:@{@"language":@"en",@"document":original} size:NSMakeSize(1180,760) error:&error];
  require(page!=nil,error.localizedDescription.UTF8String ?: "Native image creation page failed");
  page.onError=^(NSError* value){failure=value;};configureResources(page,resources,root,^(NSError* value){failure=value;});
  NSWindow* window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1180,760) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;page.view.frame=window.contentView.bounds;[window.contentView addSubview:page.view];[window makeKeyAndOrderFront:nil];
  [page start];waitUntil(^{return page.ready||failure!=nil;},20,"Native image first frame timed out");require(!failure,"Native image page failed");
  command(page,@{@"type":@"thaw"});[page editorTestScript:@"document.querySelector('#layers button[data-layer-id=\"1\"]').click();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"document.getElementById('model-workspace').click();"];command(page,@{@"type":@"snapshot"});
  [page editorTestScript:@"document.getElementById('model-image-create').click();"];[page editorTestAwaitInput:@"#model-image-root" value:@"Root"];
  [page editorTestScript:@"document.getElementById('model-image-confirm').click();"];
  NSDictionary* converted=command(page,@{@"type":@"freeze"})[@"document"],*overrides=converted[@"resourceOverrides"];
  require(overrides.count==3,"Native image conversion did not publish exactly three resources");
  require([converted[@"scene"][@"objects"][1] isEqual:scene[@"objects"][1]],"Native conversion changed shared image layer");
  NSString* modelPath=converted[@"scene"][@"objects"][0][@"image"];
  require(![modelPath isEqual:scene[@"objects"][0][@"image"]],"Native conversion did not retarget selected layer");
  NSData* bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:overrides[modelPath]]];
  require(bytes!=nil&&[resourceHash(bytes) isEqual:overrides[modelPath]],"Native image model hash mismatch");
  NSDictionary* model=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];NSString* mdl=model[@"puppet"];
  bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:overrides[mdl]]];
  require(bytes.length>8&&[resourceHash(bytes) isEqual:overrides[mdl]],"Native image mesh hash mismatch");
  command(page,@{@"type":@"mark-saved",@"document":converted});require(![command(page,@{@"type":@"freeze"})[@"dirty"] boolValue],"Native image save remained dirty");
  command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:original],"Native image one-step undo failed");
  command(page,@{@"type":@"redo"});require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:converted],"Native image redo failed");
  if(paint){
  [page editorTestScript:@"document.getElementById('model-create').click();"];[page editorTestAwaitInput:@"#model-new-name" value:@"Bone"];
  [page editorTestScript:@"document.getElementById('model-new-name').value='Fixed';document.getElementById('model-new-parent').value='-1';document.getElementById('model-new-confirm').click();"];
  NSDictionary* brushBase=command(page,@{@"type":@"snapshot"})[@"document"];
  [page editorTestScript:@"const mode=document.getElementById('model-map-tool');mode.value='paint';mode.dispatchEvent(new Event('change',{bubbles:true}));document.getElementById('model-brush-strength').value='1';"];
  [page editorTestAwaitInput:@"#model-map-tool" value:@"paint"];
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:brushBase],"Native brush settings changed document content");
  [page editorTestPaintCorner];NSDictionary* painted=command(page,@{@"type":@"freeze"})[@"document"];
  NSString* paintedVersion=painted[@"resourceOverrides"][mdl];require(![paintedVersion isEqual:brushBase[@"resourceOverrides"][mdl]],"Native CEF pointer did not paint mesh weights");
  bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:paintedVersion]];require(bytes!=nil&&[resourceHash(bytes) isEqual:paintedVersion],"Native brush MDL hash mismatch");
  command(page,@{@"type":@"mark-saved",@"document":painted});command(page,@{@"type":@"thaw"});command(page,@{@"type":@"undo"});
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:brushBase],"Native brush undo did not restore one stroke");command(page,@{@"type":@"redo"});
  require([command(page,@{@"type":@"snapshot"})[@"document"] isEqual:painted],"Native brush redo failed");
  }
  __block BOOL released=NO;[page closeWithCompletion:^(NSError* value){failure=value;released=YES;}];waitUntil(^{return released;},7,"Native image editor close timed out");require(!failure,"Native image editor close failed");[window close];
  fprintf(stderr,"Native image creation: real owned files, Model dialog, three staged hashes, shared isolation, freeze/save and one-step undo/redo passed\n");
  if(paint)fprintf(stderr,"Native CEF brush pointer, staged weight resource and one-step brush history passed\n");
}
