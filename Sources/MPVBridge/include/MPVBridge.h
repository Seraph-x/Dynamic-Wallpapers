#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^DWMPVFrameHandler)(NSData *rgba, NSDictionary<NSString *, id> *metadata);
typedef void (^DWMPVErrorHandler)(NSError *error);

/// Call from main; all callbacks run on main. Synchronous core calls and render API
/// calls use independent serial queues. Rendering never waits for control or main.
/// Explicit close is required; callback registration owns the bridge until teardown.
@interface DWMPVBridge : NSObject
- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height fill:(BOOL)fill;
/// First delivery requires a successfully rendered PRESENT, non-REDRAW/non-REPEAT
/// frame. Metadata contains firstDecodedFrameFlags (NSNumber), actual controlQueueLabel
/// and renderQueueLabel (NSString), and coalescedFrameCount (NSNumber). Delivery is
/// bounded to one main callback plus one replaceable latest frame; decoding continues.
- (void)startPath:(NSString *)path frame:(DWMPVFrameHandler)frame failure:(DWMPVErrorHandler)failure;
- (BOOL)setPaused:(BOOL)paused error:(NSError **)error;
- (BOOL)setMuted:(BOOL)muted volume:(double)volume error:(NSError **)error;
- (nullable NSNumber *)numberProperty:(NSString *)name error:(NSError **)error;
- (nullable NSNumber *)flagProperty:(NSString *)name error:(NSError **)error;
/// Gate possibly audible playback with setMuted synchronously before calling close.
/// Completion follows native destruction and all queued frame-delivery acknowledgments.
- (void)closeWithCompletion:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
