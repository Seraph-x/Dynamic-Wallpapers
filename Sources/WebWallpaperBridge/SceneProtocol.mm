#import <Foundation/Foundation.h>
#include "SceneProtocol.hpp"
#include <cmath>
#include <stdexcept>

namespace dw {
SceneRoute sceneRoute(const std::string& path, const std::string& method, bool mainFrame) {
  if (path.find('\0') != std::string::npos || path.find('\\') != std::string::npos)
    throw std::runtime_error("Invalid scene route");
  if (path == "__scene/event") {
    if (method != "POST" || !mainFrame) throw std::runtime_error("Scene events require main-frame POST");
    return {SceneMount::event, {}};
  }
  if (method != "GET") throw std::runtime_error("Scene resources require GET");
  if (path == "__scene/config") return {SceneMount::config, {}};
  for (auto [prefix, mount] : {std::pair{"__runtime/", SceneMount::runtime}, {"__project/", SceneMount::project}}) {
    if (!path.starts_with(prefix)) continue;
    auto relative = path.substr(std::string(prefix).size());
    size_t position = 0;
    do {
      auto end = relative.find('/', position);
      auto part = relative.substr(position, end - position);
      if (part.empty() || part == "." || part == "..") throw std::runtime_error("Invalid scene resource path");
      if (end == std::string::npos) break;
      position = end + 1;
    } while (true);
    return {mount, relative};
  }
  throw std::runtime_error("Unknown scene route");
}
static bool integer(id value, uint64_t minimum, uint64_t maximum) {
  if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
  double number = [value doubleValue];
  return std::isfinite(number) && number >= minimum && number <= maximum && std::floor(number) == number;
}
static bool text(id value, NSUInteger maximum) {
  return [value isKindOfClass:NSString.class] && [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 0 &&
      [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= maximum && [value rangeOfString:@"\0"].location == NSNotFound;
}
SceneEvent parseSceneEvent(const std::string& body, const std::string& sceneID, uint64_t generation) { @autoreleasepool {
  if (body.empty() || body.size() > 8192) throw std::runtime_error("Scene event body exceeds bounds");
  NSData* data = [NSData dataWithBytes:body.data() length:body.size()];
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![object isKindOfClass:NSDictionary.class]) throw std::runtime_error("Scene event must be a JSON object");
  NSDictionary* event = object;
  NSString* expected = [NSString stringWithUTF8String:sceneID.c_str()];
  if (![event[@"sceneID"] isEqual:expected] || !integer(event[@"generation"], 1, 9007199254740991ULL) ||
      [event[@"generation"] unsignedLongLongValue] != generation || !text(event[@"type"], 32))
    throw std::runtime_error("Stale or invalid scene event identity");
  NSString* type = event[@"type"];
  NSString* payload;
  if ([type isEqual:@"ready"] && integer(event[@"frame"], 1, 9007199254740991ULL)) payload = @"frame";
  else if ([type isEqual:@"error"] && text(event[@"message"], 2048)) payload = @"message";
  else if ([type isEqual:@"command-ack"] && text(event[@"commandID"], 128)) payload = @"commandID";
  else throw std::runtime_error("Invalid scene event payload");
  NSSet* keys = [NSSet setWithArray:@[@"type", @"sceneID", @"generation", payload]];
  if (![[NSSet setWithArray:event.allKeys] isEqual:keys]) throw std::runtime_error("Unknown scene event fields");
  SceneEvent result{type.UTF8String, {}, {}};
  if ([payload isEqual:@"message"]) result.message = [event[payload] UTF8String];
  if ([payload isEqual:@"commandID"]) result.commandID = [event[payload] UTF8String];
  return result;
} }
}  // namespace dw
