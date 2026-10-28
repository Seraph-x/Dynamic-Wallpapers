#import <Foundation/Foundation.h>
#include "SceneProtocol.hpp"
#include <cmath>
#include <stdexcept>
#include <string_view>

namespace dw {
SceneRoute sceneRoute(const std::string& path, const std::string& method, bool mainFrame) {
  if (path.find('\0') != std::string::npos || path.find('\\') != std::string::npos)
    throw std::runtime_error("Invalid scene route");
  if (path == "__scene/event") {
    if (method != "POST" || !mainFrame) throw std::runtime_error("Scene events require main-frame POST");
    return {SceneMount::event, {}};
  }
  if (method != "GET") throw std::runtime_error("Scene resources require GET");
  if (path == "__scene/spectrum") {
    if (!mainFrame) throw std::runtime_error("Scene spectrum requires the trusted main frame");
    return {SceneMount::spectrum, {}};
  }
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
static std::string spectrumJSON(const std::string& id, uint64_t generation,
                                const std::vector<double>& left, const std::vector<double>& right) {
  auto channel = [](const std::vector<double>& values) {
    if (values.size() != 64) throw std::runtime_error("Spectrum requires 64 bands per channel");
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:64];
    for (double value : values) {
      if (!std::isfinite(value) || value < 0 || value > 1) throw std::runtime_error("Invalid spectrum value");
      [result addObject:@(value)];
    }
    return result;
  };
  NSDictionary* payload = @{@"sceneID": @(id.c_str()), @"generation": @(generation),
                             @"left": channel(left), @"right": channel(right)};
  NSError* error = nil;
  NSData* data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
  if (!data) throw std::runtime_error("Could not serialize scene spectrum");
  return std::string(static_cast<const char*>(data.bytes), data.length);
}
bool SceneSession::replaceSpectrum(const std::vector<double>& left, const std::vector<double>& right) { @autoreleasepool {
  auto json = dw::spectrumJSON(sceneID, generation, left, right);
  std::lock_guard lock(mutex);
  if (retired) return false;
  spectrum = std::move(json);
  return true;
} }
std::optional<std::string> SceneSession::spectrumJSON() { @autoreleasepool {
  std::lock_guard lock(mutex);
  if (retired) return std::nullopt;
  if (spectrum.empty()) spectrum = dw::spectrumJSON(sceneID, generation, std::vector<double>(64), std::vector<double>(64));
  return spectrum;
} }
// Foundation accepts trailing commas; issue payloads use strict JSON before
// Foundation decodes either the seven-field legacy schema or the external
// resource descriptor nested in its eighth field.
class IssueJSONSyntax final {
 public:
  explicit IssueJSONSyntax(const std::string& json) : input(json) {}
  bool valid(NSUInteger fields) {
    whitespace();
    if (!take('{')) return false;
    whitespace();
    NSUInteger count = 0;
    if (!take('}')) {
      do {
        whitespace();
        if (!string()) return false;
        whitespace();
        if (!take(':')) return false;
        whitespace();
        if (!value()) return false;
        ++count;
        whitespace();
        if (take('}')) break;
        if (!take(',')) return false;
      } while (true);
    }
    whitespace();
    return index == input.size() && count == fields;
  }
 private:
  const std::string& input;
  size_t index = 0;
  void whitespace() { while (index < input.size() && std::string_view(" \t\r\n").find(input[index]) != std::string_view::npos) ++index; }
  bool take(char character) { if (index == input.size() || input[index] != character) return false; ++index; return true; }
  bool digit() { if (index == input.size() || input[index] < '0' || input[index] > '9') return false; ++index; return true; }
  bool string() {
    if (!take('"')) return false;
    while (index < input.size()) {
      const auto character = static_cast<unsigned char>(input[index++]);
      if (character == '"') return true;
      if (character < 0x20) return false;
      if (character != '\\') continue;
      if (index == input.size()) return false;
      const char escape = input[index++];
      if (escape != 'u') {
        if (std::string_view("\"\\/bfnrt").find(escape) == std::string_view::npos) return false;
        continue;
      }
      for (int offset = 0; offset < 4; ++offset)
        if (index == input.size() || std::string_view("0123456789abcdefABCDEF").find(input[index++]) == std::string_view::npos) return false;
    }
    return false;
  }
  bool scalar() {
    if (index < input.size() && input[index] == '"') return string();
    for (const std::string_view literal : {"null", "true", "false"}) {
      if (input.compare(index, literal.size(), literal) != 0) continue;
      index += literal.size(); return true;
    }
    take('-');
    if (!take('0')) { if (!digit()) return false; while (digit()) {} }
    if (take('.')) { if (!digit()) return false; while (digit()) {} }
    if (take('e') || take('E')) {
      if (!take('+')) take('-');
      if (!digit()) return false;
      while (digit()) {}
    }
    return true;
  }
  bool value() {
    whitespace();
    if (index < input.size() && input[index] == '{') return object(5);
    if (index < input.size() && input[index] == '[') return array();
    return scalar();
  }
  bool object(NSUInteger expectedFields) {
    if (!take('{')) return false;
    whitespace();
    NSUInteger fields = 0;
    if (take('}')) return expectedFields == 0;
    do {
      whitespace(); if (!string()) return false;
      whitespace(); if (!take(':')) return false;
      if (!value()) return false;
      ++fields;
      whitespace();
      if (take('}')) return fields == expectedFields;
      if (!take(',')) return false;
    } while (true);
  }
  bool array() {
    if (!take('[')) return false;
    whitespace();
    if (take(']')) return true;
    do {
      if (!value()) return false;
      whitespace();
      if (take(']')) return true;
      if (!take(',')) return false;
    } while (true);
  }
};
struct IssueValidationJSON {
  std::string bytes;
  bool rawDisplay = false;
};
static unsigned unicodeEscape(const std::string& input, size_t index) {
  unsigned value = 0;
  for (size_t offset = 2; offset < 6; ++offset) {
    const char digit = input[index + offset];
    value = value * 16 + (digit <= '9' ? digit - '0' : (digit | 0x20) - 'a' + 10);
  }
  return value;
}
// Called only after strict JSON syntax validation. Foundation cannot represent
// isolated UTF16 escapes. Escape those again solely in the schema-check copy;
// the event retains the original bytes for explicitly labelled raw display.
static IssueValidationJSON issueValidationJSON(const std::string& input) {
  IssueValidationJSON result;
  result.bytes.reserve(input.size());
  bool inString = false;
  for (size_t index = 0; index < input.size();) {
    const char character = input[index];
    if (character == '"') inString = !inString;
    if (!inString || character != '\\') {
      result.bytes += character; ++index; continue;
    }
    if (input[index + 1] != 'u') {
      result.bytes.append(input, index, 2); index += 2; continue;
    }
    const unsigned unit = unicodeEscape(input, index);
    const bool high = unit >= 0xd800 && unit <= 0xdbff;
    const bool low = unit >= 0xdc00 && unit <= 0xdfff;
    if (high && index + 12 <= input.size() && input[index + 6] == '\\' && input[index + 7] == 'u') {
      const unsigned next = unicodeEscape(input, index + 6);
      if (next >= 0xdc00 && next <= 0xdfff) {
        result.bytes.append(input, index, 12); index += 12; continue;
      }
    }
    if (high || low) { result.bytes += '\\'; result.rawDisplay = true; }
    result.bytes.append(input, index, 6); index += 6;
  }
  return result;
}
static bool validateScriptIssue(const std::string& bytes) {
  NSData* data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
  if (![[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding])
    throw std::runtime_error("Scene script issue must be valid UTF8");
  const auto validation = issueValidationJSON(bytes);
  NSData* validationData = [NSData dataWithBytes:validation.bytes.data() length:validation.bytes.size()];
  id value = [NSJSONSerialization JSONObjectWithData:validationData options:0 error:nil];
  if (![value isKindOfClass:NSDictionary.class] || ([value count] != 7 && [value count] != 8))
    throw std::runtime_error("Scene script issue must be a strict JSON object");
  NSDictionary* issue = value;
  NSMutableSet* keys = [NSMutableSet setWithArray:@[@"layerId", @"layerName", @"target", @"phase", @"message", @"line", @"count"]];
  if ([issue count] == 8) [keys addObject:@"source"];
  if (![[NSSet setWithArray:issue.allKeys] isEqual:keys]) throw std::runtime_error("Unknown or missing scene script issue fields");
  id layer = issue[@"layerId"];
  if (layer != NSNull.null && (![layer isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)layer) == CFBooleanGetTypeID() || !std::isfinite([layer doubleValue])))
    throw std::runtime_error("Invalid scene script issue layer ID");
  for (NSString* key in @[@"layerName", @"target", @"phase", @"message"])
    if (![issue[key] isKindOfClass:NSString.class]) throw std::runtime_error("Scene script issue display fields must be strings");
  if ((issue[@"line"] != NSNull.null && !integer(issue[@"line"], 1, 9007199254740991ULL)) ||
      !integer(issue[@"count"], 1, 9007199254740991ULL)) throw std::runtime_error("Invalid scene script issue line or count");
  if (id rawSource = issue[@"source"]) {
    if (validation.rawDisplay || ![rawSource isKindOfClass:NSDictionary.class])
      throw std::runtime_error("Invalid scene script resource source Unicode or type");
    NSDictionary* source = rawSource;
    NSSet* sourceKeys = [NSSet setWithArray:@[@"kind", @"path", @"sha256", @"pointer", @"text"]];
    if (![[NSSet setWithArray:source.allKeys] isEqual:sourceKeys] || ![source[@"kind"] isEqual:@"resource"] ||
        ![source[@"path"] isKindOfClass:NSString.class] || ![source[@"sha256"] isKindOfClass:NSString.class] ||
        ![source[@"pointer"] isKindOfClass:NSArray.class] || ![source[@"text"] isKindOfClass:NSString.class])
      throw std::runtime_error("Invalid scene script resource source fields");
    NSString* path = source[@"path"];
    if (path.length == 0 || [path rangeOfString:@"\0"].location != NSNotFound ||
        [path rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\:"]].location != NSNotFound)
      throw std::runtime_error("Invalid scene script resource path");
    for (NSString* part in [path componentsSeparatedByString:@"/"])
      if (part.length == 0 || [part isEqual:@"."] || [part isEqual:@".."])
        throw std::runtime_error("Invalid scene script resource path");
    NSString* digest = source[@"sha256"];
    if (digest.length != 64 || [digest rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound)
      throw std::runtime_error("Invalid scene script resource digest");
    for (id component in source[@"pointer"])
      if (!([component isKindOfClass:NSString.class] && [component rangeOfString:@"\0"].location == NSNotFound) &&
          !integer(component, 0, 9007199254740991ULL))
        throw std::runtime_error("Invalid scene script resource pointer");
    if ([source[@"text"] rangeOfString:@"\0"].location != NSNotFound)
      throw std::runtime_error("Invalid scene script resource text");
  }
  const NSUInteger expectedFields = issue[@"source"] ? 8 : 7;
  if (!IssueJSONSyntax(bytes).valid(expectedFields))
    throw std::runtime_error("Scene script issue must be a strict JSON object");
  return validation.rawDisplay;
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
  if ([type isEqual:@"script-issue-part"]) {
    NSSet* keys = [NSSet setWithArray:@[@"type", @"sceneID", @"generation", @"transferID", @"ordinal", @"final", @"data"]];
    if (![[NSSet setWithArray:event.allKeys] isEqual:keys]) throw std::runtime_error("Unknown scene script issue part fields");
    id final = event[@"final"];
    if (!text(event[@"transferID"], 128) || !integer(event[@"ordinal"], 0, 9007199254740991ULL) ||
        ![final isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)final) != CFBooleanGetTypeID() ||
        ![event[@"data"] isKindOfClass:NSString.class]) throw std::runtime_error("Invalid scene script issue part");
    NSData* fragment = [[NSData alloc] initWithBase64EncodedString:event[@"data"] options:0];
    if (!fragment || ![[fragment base64EncodedStringWithOptions:0] isEqual:event[@"data"]])
      throw std::runtime_error("Invalid scene script issue base64");
    SceneEvent result{};
    result.type = "script-issue-part";
    result.issuePart = SceneScriptIssuePart{[event[@"transferID"] UTF8String],
        std::string(static_cast<const char*>(fragment.bytes), fragment.length),
        [event[@"ordinal"] unsignedLongLongValue], [final boolValue] == YES};
    return result;
  }
  NSString* payload;
  if ([type isEqual:@"ready"] && integer(event[@"frame"], 1, 9007199254740991ULL)) payload = @"frame";
  else if ([type isEqual:@"error"] && text(event[@"message"], 2048)) payload = @"message";
  else if ([type isEqual:@"command-ack"] && text(event[@"commandID"], 128)) payload = @"commandID";
  else throw std::runtime_error("Invalid scene event payload");
  NSSet* keys = [NSSet setWithArray:@[@"type", @"sceneID", @"generation", payload]];
  if (![[NSSet setWithArray:event.allKeys] isEqual:keys]) throw std::runtime_error("Unknown scene event fields");
  SceneEvent result{}; result.type = type.UTF8String;
  if ([payload isEqual:@"message"]) result.message = [event[payload] UTF8String];
  if ([payload isEqual:@"commandID"]) result.commandID = [event[payload] UTF8String];
  return result;
} }
bool SceneSession::receive(const std::string& body) { @autoreleasepool {
  std::lock_guard lock(mutex);
  auto event = parseSceneEvent(body, sceneID, generation);
  if (retired) { issueTransfer.reset(); return false; }
  if (!event.issuePart) { events.push_back(std::move(event)); return true; }
  const auto& part = *event.issuePart;
  if (completedIssueTransfers.contains(part.transferID))
    throw std::runtime_error("Repeated completed scene script issue transfer");
  if ((!issueTransfer && part.ordinal != 0) ||
      (issueTransfer && (part.transferID != issueTransfer->id || part.ordinal != issueTransfer->nextOrdinal)))
    throw std::runtime_error("Out-of-order or interleaved scene script issue transfer");
  if (part.final) {
    std::string bytes = issueTransfer ? issueTransfer->bytes : std::string{};
    bytes.append(part.bytes);
    const bool rawDisplay = validateScriptIssue(bytes);
    SceneEvent complete{}; complete.type = rawDisplay ? "script-issue-raw" : "script-issue"; complete.payload = std::move(bytes);
    completedIssueTransfers.insert(part.transferID);
    issueTransfer.reset();
    events.push_back(std::move(complete));
    return true;
  }
  if (!issueTransfer) issueTransfer = IssueTransfer{part.transferID, {}, 0};
  issueTransfer->bytes.append(part.bytes);
  ++issueTransfer->nextOrdinal;
  return true;
} }
void SceneSession::retire() {
  std::lock_guard lock(mutex);
  retired = true; issueTransfer.reset(); completedIssueTransfers.clear(); events.clear();
}
bool EditorSession::receive(const std::string& body) { @autoreleasepool {
  NSData* data = [NSData dataWithBytes:body.data() length:body.size()];
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![value isKindOfClass:NSDictionary.class]) throw std::runtime_error("Editor event must be an object");
  NSDictionary* object = value;
  if (![object[@"session"] isEqual:@(session.c_str())] || !integer(object[@"generation"], 1, 9007199254740991ULL) ||
      [object[@"generation"] unsignedLongLongValue] != generation || !text(object[@"type"], 32))
    throw std::runtime_error("Stale or invalid Editor event identity");
  NSString* type = object[@"type"];
  NSMutableSet* keys = [NSMutableSet setWithArray:@[@"type", @"session", @"generation"]];
  EditorEvent event{type.UTF8String, {}, {}, false};
  if ([type isEqual:@"preview"]) { /* Payload-free native snapshot request. */ }
  else if ([type isEqual:@"ready"] && integer(object[@"frame"], 1, 9007199254740991ULL)) [keys addObject:@"frame"];
  else if ([type isEqual:@"dirty"] && [object[@"dirty"] isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)object[@"dirty"]) == CFBooleanGetTypeID()) {
    [keys addObject:@"dirty"]; event.dirty = [object[@"dirty"] boolValue];
  } else if ([type isEqual:@"reply"] && text(object[@"id"], 128) && [object[@"payload"] isKindOfClass:NSDictionary.class]) {
    [keys addObjectsFromArray:@[@"id", @"payload"]]; event.id = [object[@"id"] UTF8String];
    NSData* payload = [NSJSONSerialization dataWithJSONObject:object[@"payload"] options:0 error:nil];
    event.payload.assign(static_cast<const char*>(payload.bytes), payload.length);
  } else if ([type isEqual:@"resource"] && text(object[@"id"], 128)) {
    [keys addObjectsFromArray:@[@"id", @"action"]]; event.id = [object[@"id"] UTF8String];
    if ([object[@"action"] isEqual:@"stage"] && [object[@"data"] isKindOfClass:NSString.class]) {
      NSString* encoded = object[@"data"];
      NSData* bytes = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
      if (!bytes || ![[bytes base64EncodedStringWithOptions:0] isEqual:encoded]) throw std::runtime_error("Invalid Editor resource base64");
      [keys addObject:@"data"];
    } else if ([object[@"action"] isEqual:@"read"] && [object[@"version"] isKindOfClass:NSString.class] && [object[@"version"] length] == 64 &&
        [object[@"version"] rangeOfString:@"^[a-f0-9]{64}$" options:NSRegularExpressionSearch].location != NSNotFound) {
      [keys addObject:@"version"];
    } else if (![object[@"action"] isEqual:@"list"]) throw std::runtime_error("Invalid Editor resource request");
    NSData* payload = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    event.payload.assign(static_cast<const char*>(payload.bytes), payload.length);
  } else if ([type isEqual:@"error"] && text(object[@"message"], 2048)) {
    [keys addObject:@"message"]; event.payload = [object[@"message"] UTF8String];
  } else throw std::runtime_error("Invalid Editor event payload");
  if (![keys isEqual:[NSSet setWithArray:object.allKeys]]) throw std::runtime_error("Unknown Editor event fields");
  std::lock_guard lock(mutex);
  if (retired) return false;
  events.push_back(std::move(event)); return true;
} }
}  // namespace dw
