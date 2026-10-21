#import "include/WebWallpaperBridge.h"

static inline void DWRequireWebMainThread(void) {
  if (!NSThread.isMainThread)
    [NSException raise:NSInternalInconsistencyException format:@"CEF API requires the application main thread"];
}

static inline NSError* DWWebError(NSString* message) {
  return [NSError errorWithDomain:@"DynamicWallpaper.Web" code:1
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}
@interface DWWebRuntime (PageOwnership)
- (void)retirePage:(DWWebPage*)page;
@end
@interface DWWebPage (RuntimeInternal)
- (instancetype)initWithRuntime:(DWWebRuntime*)runtime root:(NSString*)root entry:(NSString*)entry
                          size:(NSSize)size scale:(CGFloat)scale;
- (void)tick;
@end
