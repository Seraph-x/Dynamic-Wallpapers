#import <Foundation/Foundation.h>
#include "WebAudioBuffer.hpp"
#include <memory>

@interface DWWebAudioOutput : NSObject
- (instancetype)initWithChangeCallback:(std::function<void()>)changed error:(NSError**)error;
- (std::shared_ptr<DWWebAudioBuffer>)buffer;
- (void)close;
@end
