#import <Cocoa/Cocoa.h>

// Test-only observation and native transitions. Never grant the window capabilities here.

static NSArray *FullscreenMenuItems(NSMenu *menu) {
    [menu update];
    NSMutableArray *items = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == @selector(toggleFullScreen:)) {
            [items addObject:@{@"title": item.title, @"enabled": @(item.enabled),
                @"key": item.keyEquivalent, @"modifiers": @(item.keyEquivalentModifierMask)}];
        }
        if (item.submenu) [items addObjectsFromArray:FullscreenMenuItems(item.submenu)];
    }
    return items;
}

static NSDictionary *WindowSnapshot(NSWindow *window, NSString *errorMessage) {
    NSButton *zoom = [window standardWindowButton:NSWindowZoomButton];
    NSWindowCollectionBehavior behavior = window.collectionBehavior;
    return @{
        @"bundle": NSBundle.mainBundle.bundleIdentifier,
        @"readinessError": errorMessage ?: @"",
        @"finishedLaunching": @(NSRunningApplication.currentApplication.finishedLaunching),
        @"active": @(NSApp.active),
        @"keyWindow": @(window.keyWindow),
        @"mainWindow": @(window.mainWindow),
        @"attachedSheet": @(window.attachedSheet != nil),
        @"modalWindow": @(NSApp.modalWindow != nil),
        @"policy": @(NSApp.activationPolicy),
        @"windowClass": NSStringFromClass(window.class),
        @"title": window.title,
        @"style": @(window.styleMask),
        @"resizable": @((window.styleMask & NSWindowStyleMaskResizable) != 0),
        @"fullscreen": @((window.styleMask & NSWindowStyleMaskFullScreen) != 0),
        @"behavior": @(behavior),
        @"primary": @((behavior & NSWindowCollectionBehaviorFullScreenPrimary) != 0),
        @"auxiliary": @((behavior & NSWindowCollectionBehaviorFullScreenAuxiliary) != 0),
        @"none": @((behavior & NSWindowCollectionBehaviorFullScreenNone) != 0),
        @"zoomEnabled": @(zoom.enabled),
        @"zoomAction": zoom.action ? NSStringFromSelector(zoom.action) : @"<none>",
        @"contentMinSize": NSStringFromSize(window.contentMinSize),
        @"contentMaxSize": NSStringFromSize(window.contentMaxSize),
        @"fullscreenMenuItems": FullscreenMenuItems(NSApp.mainMenu)
    };
}

static void WriteReport(NSDictionary *value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:&error];
    NSString *path = NSProcessInfo.processInfo.environment[@"FULLSCREEN_PROBE_OUTPUT"];
    NSString *partial = [path stringByAppendingString:@".partial"];
    if (!data || ![data writeToFile:partial options:NSDataWritingWithoutOverwriting error:&error] ||
        ![NSFileManager.defaultManager moveItemAtPath:partial toPath:path error:&error]) {
        fprintf(stderr, "Window capabilities report failed: %s\n", error.description.UTF8String);
        abort();
    }
    printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}

static void RecordWindow(NSWindow *window, NSString *errorMessage) {
    if (errorMessage) {
        WriteReport(WindowSnapshot(window, errorMessage));
        return;
    }
    NSMutableDictionary *report = [@{@"before": WindowSnapshot(window, nil)} mutableCopy];
    NSMutableArray *events = [NSMutableArray array];
    NSMutableArray *observers = [NSMutableArray array];
    NSArray *names = @[NSWindowWillEnterFullScreenNotification, NSWindowDidEnterFullScreenNotification,
        NSWindowWillExitFullScreenNotification, NSWindowDidExitFullScreenNotification];
    for (NSString *name in names) {
        [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:window
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) { [events addObject:notification.name]; }]];
    }
    __block BOOL exiting = NO;
    __block NSDate *started = NSDate.date;
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        if (!exiting && [events containsObject:NSWindowDidEnterFullScreenNotification]) {
            report[@"entered"] = WindowSnapshot(window, nil);
            exiting = YES;
            started = NSDate.date;
            [window toggleFullScreen:nil];
            return;
        }
        BOOL done = exiting && [events containsObject:NSWindowDidExitFullScreenNotification];
        BOOL timedOut = [NSDate.date timeIntervalSinceDate:started] > 6;
        if (!done && !timedOut) return;
        [timer invalidate];
        for (id observer in observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
        report[@"events"] = events;
        report[@"final"] = WindowSnapshot(window, nil);
        report[@"error"] = done ? @"" : (exiting ? @"Native full-screen exit timed out after 6 seconds" :
            @"Native full-screen entry timed out after 6 seconds");
        WriteReport(report);
    }];
    [window toggleFullScreen:nil];
}

__attribute__((constructor)) static void InspectWindowCapabilities(void) {
    @autoreleasepool {
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSString *home = environment[@"CFFIXED_USER_HOME"];
        NSString *expected = environment[@"FULLSCREEN_PROBE_ID"];
        NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        if (!home || !expected || ![NSBundle.mainBundle.bundleIdentifier isEqual:expected] ||
            ![support.path hasPrefix:[home stringByAppendingString:@"/Library/"]]) {
            fprintf(stderr, "Refusing window probe outside the isolated app and home.\n");
            abort();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDate *started = NSDate.date;
            [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
                BOOL timedOut = [NSDate.date timeIntervalSinceDate:started] > 10;
                for (NSWindow *window in NSApp.windows) {
                    if (window.isVisible && window.level == NSNormalWindowLevel &&
                        [window.title isEqual:@"Dynamic Wallpaper"]) {
                        BOOL ready = NSRunningApplication.currentApplication.finishedLaunching && NSApp.active && window.keyWindow
                            && NSApp.activationPolicy == [environment[@"FULLSCREEN_PROBE_POLICY"] integerValue];
                        if (!ready && !timedOut) return;
                        [timer invalidate];
                        RecordWindow(window, ready ? nil : @"Launch/policy/activation/key window not ready within 10 seconds");
                        return;
                    }
                }
                if (timedOut) {
                    fprintf(stderr, "Native window was not ready within 10 seconds.\n");
                    abort();
                }
            }];
        });
    }
}
