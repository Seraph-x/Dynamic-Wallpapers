#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@class DWWebPage;

/// Call before SwiftUI/NSApplication startup. This does not load or initialize CEF.
NS_SWIFT_UI_ACTOR FOUNDATION_EXPORT void DWWebCreateApplication(void);
/// Posted synchronously before AppKit can reject a quit request due to attached sheets.
FOUNDATION_EXPORT NSNotificationName const DWApplicationWillRequestTerminationNotification;

/// One lazy CEF runtime per application process. Page closure never shuts it down.
NS_SWIFT_UI_ACTOR @interface DWWebRuntime : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithFrameworkDirectory:(NSString *)frameworkDirectory
                         helperExecutable:(NSString *)helperExecutable
                           cacheDirectory:(NSString *)cacheDirectory NS_DESIGNATED_INITIALIZER;
@property(nonatomic, readonly) NSUInteger initializationCount;
@property(nonatomic, readonly) NSUInteger shutdownCount;
@property(nonatomic, readonly) NSUInteger activePageCount;
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
- (nullable DWWebPage *)pageWithProjectRoot:(NSString *)root entry:(NSString *)entry
                                     size:(NSSize)size scale:(CGFloat)scale
                                    error:(NSError * _Nullable * _Nullable)error;
/// Trusted scene shell and selected project use separate descriptor-bound roots.
- (nullable DWWebPage *)scenePageWithProjectRoot:(NSString *)root runtimeRoot:(NSString *)runtimeRoot
    entry:(NSString *)entry representation:(NSString *)representation sceneID:(NSString *)sceneID
    generation:(uint64_t)generation size:(NSSize)size scale:(CGFloat)scale
    error:(NSError * _Nullable * _Nullable)error;
/// Only legal after every page has actually closed. No forced-close success path.
- (BOOL)shutdownWithError:(NSError * _Nullable * _Nullable)error;
@end

/// The frame, controlled native audio output and lifetime of one webpage.
/// All API calls and callbacks below are on the application main thread.
NS_SWIFT_UI_ACTOR @interface DWWebPage : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSView *view;
@property(nonatomic, readonly) NSString *origin;
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly) BOOL closed;
@property(nonatomic, readonly) BOOL defaultAudioMuted;
@property(nonatomic, readonly) NSUInteger frameRate;
@property(nonatomic, readonly) NSDictionary<NSString*, NSNumber*>* audioDiagnostics;
@property(nonatomic, copy, nullable) void (^onReady)(void);
@property(nonatomic, copy, nullable) void (^onError)(NSError *error);
- (void)start;
- (BOOL)setOutputGain:(double)gain error:(NSError * _Nullable * _Nullable)error;
- (BOOL)setFrameRate:(NSUInteger)frameRate error:(NSError * _Nullable * _Nullable)error;
- (BOOL)sendClickAtPoint:(NSPoint)point clickCount:(NSInteger)clickCount
                  error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(sendClick(at:clickCount:));
/// Scene commands complete only after the trusted engine acknowledges execution.
- (void)setScenePlaying:(BOOL)playing completion:(void (^)(NSError * _Nullable error))completion;
- (void)setSceneVolume:(double)volume muted:(BOOL)muted completion:(void (^)(NSError * _Nullable error))completion;
/// fit is exactly cover or contain.
- (void)setSceneFit:(NSString *)fit completion:(void (^)(NSError * _Nullable error))completion;
- (void)setSceneFrameRate:(NSUInteger)frameRate completion:(void (^)(NSError * _Nullable error))completion;
/// Replace the latest stereo spectrum. Exactly 64 finite values in [0,1] per channel.
- (BOOL)setSceneSpectrumLeft:(NSArray<NSNumber*>*)left right:(NSArray<NSNumber*>*)right
                       error:(NSError * _Nullable * _Nullable)error;
/// Normalized scene coordinates [0,1]; kind is move, leave, or click.
- (BOOL)sendScenePointerAtPoint:(NSPoint)point kind:(NSString *)kind error:(NSError * _Nullable * _Nullable)error;
/// Releases the page/context; the view keeps its last submitted frame.
/// A close failure remains owned and is returned again to later callers.
- (void)closeWithCompletion:(void (^)(NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
