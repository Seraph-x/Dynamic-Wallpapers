#import <Foundation/Foundation.h>
#include "SceneProtocol.hpp"
#include "LocalProjectFiles.hpp"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>
using namespace dw;
static void require(bool value) { if (!value) throw std::runtime_error("scene protocol assertion failed"); }
template<class F> static void rejects(F action) { bool failed = false; try { action(); } catch (...) { failed = true; } require(failed); }
static std::string json(id object) {
  NSData* data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
  require(data != nil);
  return {static_cast<const char*>(data.bytes), data.length};
}
static NSMutableDictionary* issue() {
  return [@{@"layerId": @1.5, @"layerName": @"", @"target": @"origin", @"phase": @"update",
            @"message": @"failure\0雪🌈", @"line": NSNull.null, @"count": @1} mutableCopy];
}
static NSMutableDictionary* part(NSData* bytes, NSUInteger ordinal = 0, BOOL final = YES,
                                 NSString* transfer = nil) {
  if (!transfer) transfer = NSUUID.UUID.UUIDString;
  return [@{@"type": @"script-issue-part", @"sceneID": @"scene", @"generation": @7,
            @"transferID": transfer, @"ordinal": @(ordinal), @"final": @(final),
            @"data": [bytes base64EncodedStringWithOptions:0]} mutableCopy];
}
static NSData* issueBytes(NSDictionary* value) {
  return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
}
static void scriptIssueTests() {
  SceneSession session("scene", 7, "{}");
  NSData* bytes = issueBytes(issue());
  auto completed = part(bytes);
  require(session.receive(json(completed)));
  rejects([&] { session.receive(json(completed)); });
  require(session.events.size() == 1 && session.events[0].type == "script-issue");
  require(session.events[0].payload == std::string(static_cast<const char*>(bytes.bytes), bytes.length));
  for (NSString* key in @[@"layerId", @"layerName", @"target", @"phase", @"message", @"line", @"count"]) {
    auto missing = issue(); [missing removeObjectForKey:key];
    rejects([&] { session.receive(json(part(issueBytes(missing)))); });
  }
  for (NSString* key in @[@"layerName", @"target", @"phase", @"message"]) {
    auto invalid = issue(); invalid[key] = @1;
    rejects([&] { session.receive(json(part(issueBytes(invalid)))); });
  }
  for (NSString* key in @[@"line", @"count"]) {
    for (id invalid in @[@0, @(-1), @1.5, @YES, @9007199254740992ULL, @"2"]) {
      auto value = issue(); value[key] = invalid;
      rejects([&] { session.receive(json(part(issueBytes(value)))); });
    }
  }
  for (id invalid in @[@YES, @"1", @[], @{}]) {
    auto value = issue(); value[@"layerId"] = invalid;
    rejects([&] { session.receive(json(part(issueBytes(value)))); });
  }
  auto extra = issue(); extra[@"extra"] = @1;
  rejects([&] { session.receive(json(part(issueBytes(extra)))); });
  auto nullCount = issue(); nullCount[@"count"] = NSNull.null;
  rejects([&] { session.receive(json(part(issueBytes(nullCount)))); });
  auto updated = issue(); updated[@"layerId"] = NSNull.null; updated[@"line"] = @2; updated[@"count"] = @31;
  require(session.receive(json(part(issueBytes(updated)))));
  require(session.events.size() == 2);
  NSData* updatedBytes = issueBytes(updated);
  require(session.events.back().payload == std::string(static_cast<const char*>(updatedBytes.bytes), updatedBytes.length));
  for (NSString* key in @[@"layerName", @"target", @"phase", @"message"]) updated[key] = @"";
  require(session.receive(json(part(issueBytes(updated)))));
  for (NSString* key in @[@"transferID", @"ordinal", @"final", @"data"]) {
    auto missing = part(bytes); [missing removeObjectForKey:key];
    rejects([&] { session.receive(json(missing)); });
  }
  for (NSString* key in @[@"ordinal", @"final", @"transferID", @"data"]) {
    NSArray* invalids = [key isEqual:@"ordinal"] ? @[@(-1), @1.5, @YES, @9007199254740992ULL] :
      [key isEqual:@"final"] ? @[@0, @1, @"true", NSNull.null] :
      [key isEqual:@"transferID"] ? @[@"", @"bad\0id", [@"x" stringByPaddingToLength:129 withString:@"x" startingAtIndex:0], @1] :
      @[@1, @"Zg", @"Zh==", @"Zg==\n", @"@@=="];
    for (id invalid in invalids) {
      auto value = part(bytes); value[key] = invalid;
      rejects([&] { session.receive(json(value)); });
    }
  }
  for (NSDictionary* mutation in @[@{@"extra": @1}, @{@"generation": @6}, @{@"sceneID": @"other"}]) {
    auto value = part(bytes); [value addEntriesFromDictionary:mutation];
    rejects([&] { session.receive(json(value)); });
  }
  rejects([&] { session.receive(json(part([NSData dataWithBytes:"\xff" length:1]))); });
  rejects([&] { session.receive(json(part([@"[]" dataUsingEncoding:NSUTF8StringEncoding]))); });
  rejects([&] { session.receive(json(part([@"{invalid}" dataUsingEncoding:NSUTF8StringEncoding]))); });
  require(session.events.size() == 3);
  const auto valid = json(issue());
  auto malformedJSON = valid; malformedJSON.insert(malformedJSON.size() - 1, ",");
  rejects([&] { session.receive(json(part([NSData dataWithBytes:malformedJSON.data() length:malformedJSON.size()]))); });
  malformedJSON = valid; malformedJSON.insert(1, "\"count\":1,");
  rejects([&] { session.receive(json(part([NSData dataWithBytes:malformedJSON.data() length:malformedJSON.size()]))); });
}
static void scriptIssueTransferTests() {
  SceneSession session("scene", 7, "{}");
  auto value = issue();
  value[@"layerName"] = [@"雪🌈\0" stringByPaddingToLength:16000 withString:@"雪🌈\0" startingAtIndex:0];
  value[@"target"] = [@"general.雪" stringByPaddingToLength:20000 withString:@"general.雪" startingAtIndex:0];
  NSData* bytes = issueBytes(value);
  require(bytes.length > 8192);
  NSUInteger ordinal = 0;
  for (NSUInteger offset = 0; offset < bytes.length; offset += 997) {
    NSUInteger length = std::min<NSUInteger>(997, bytes.length - offset);
    BOOL final = offset + length == bytes.length;
    const auto body = json(part([bytes subdataWithRange:NSMakeRange(offset, length)], ordinal++, final, @"long-transfer"));
    require(body.size() <= 8192 && session.receive(body));
    require(session.events.size() == (final ? 1 : 0));
  }
  require(session.events[0].payload == std::string(static_cast<const char*>(bytes.bytes), bytes.length));
  NSData* small = issueBytes(issue());
  auto first = part([small subdataWithRange:NSMakeRange(0, 5)], 0, NO, @"small-transfer");
  auto last = part([small subdataWithRange:NSMakeRange(5, small.length - 5)], 1, YES, @"small-transfer");
  rejects([&] { session.receive(json(last)); });
  require(session.receive(json(first)));
  rejects([&] { session.receive(json(first)); });
  NSMutableDictionary* skipped = [last mutableCopy]; skipped[@"ordinal"] = @2;
  rejects([&] { session.receive(json(skipped)); });
  NSMutableDictionary* interleaved = [first mutableCopy]; interleaved[@"transferID"] = @"other";
  rejects([&] { session.receive(json(interleaved)); });
  NSMutableDictionary* stale = [last mutableCopy]; stale[@"generation"] = @6;
  rejects([&] { session.receive(json(stale)); });
  require(session.events.size() == 1);
  require(session.receive(json(last)));
  require(session.events.size() == 2);
  rejects([&] { session.receive(json(last)); });
  first[@"transferID"] = @"interrupted-transfer";
  last[@"transferID"] = @"interrupted-transfer";
  require(session.receive(json(first)));
  session.retired = true;
  require(!session.receive(json(last)));
  require(session.events.size() == 2);
  require(!session.receive(json(first)));
  SceneSession closing("scene", 7, "{}");
  require(closing.receive(json(first)));
  closing.retire();
  require(closing.events.empty() && !closing.receive(json(last)));
  auto oversized = part([NSMutableData dataWithLength:7000]);
  rejects([&] { parseSceneEvent(json(oversized), "scene", 7); });
}
static std::string serializedIssue(const std::string& message, const std::string& count = "1") {
  return R"({"layerId":1,"layerName":"雪","target":"color","phase":"update","message":")" + message +
      R"(","line":2,"count":)" + count + "}";
}
static void scriptIssueRawUnicodeTests() {
  SceneSession session("scene", 7, "{}");
  // JSON.stringify(('a'.repeat(199) + '😀tail').slice(0, 200)) ends in \\ud83d.
  const auto truncated = std::string(199, 'a') + R"(\ud83d)";
  const std::vector<std::pair<std::string, bool>> cases = {
    {truncated, true}, {R"(\ude00)", true}, {R"(\ud83d\ude00)", false},
    {R"(literal \\ud83d)", false}, {R"(slash \/ pair \uD83D\uDE00)", false},
    {R"(\ud83d\ude00\ude00\ud83d雪\\ud83d\ud83d\ude00)", true},
    {R"(escaped quote \" then \ud83d)", true}, {R"(\\\ud83d)", true},
  };
  for (const auto& [message, raw] : cases) {
    const auto original = serializedIssue(message);
    NSData* bytes = [NSData dataWithBytes:original.data() length:original.size()];
    const auto before = session.events.size();
    require(session.receive(json(part(bytes))));
    require(session.events.size() == before + 1);
    require(session.events.back().type == (raw ? "script-issue-raw" : "script-issue"));
    require(session.events.back().payload == original);
  }
  for (const auto count : {"1", "2", "3"}) {
    const auto original = serializedIssue(truncated, count);
    NSData* bytes = [NSData dataWithBytes:original.data() length:original.size()];
    require(session.receive(json(part(bytes))));
    require(session.events.back().type == "script-issue-raw" && session.events.back().payload == original);
  }
  const auto valid = serializedIssue(truncated);
  std::vector<std::string> invalids = {
    serializedIssue(truncated, "true"), serializedIssue(truncated, "0"),
    serializedIssue(R"(\ud83d\uZZZZ)"), serializedIssue(R"(\ud83d\x20)"),
    serializedIssue(std::string(1, char(0xff)) + R"(\ud83d)"),
  };
  auto wrongType = valid; wrongType.replace(wrongType.find("\"line\":2"), 8, "\"line\":\"2\""); invalids.push_back(wrongType);
  auto unknown = valid; unknown.insert(1, "\"extra\":0,"); invalids.push_back(unknown);
  auto duplicate = valid; duplicate.insert(1, "\"count\":1,"); invalids.push_back(duplicate);
  auto missing = valid; missing.erase(missing.find("\"line\":2,"), 9); invalids.push_back(missing);
  auto trailing = valid; trailing.insert(trailing.size() - 1, ","); invalids.push_back(trailing);
  const auto before = session.events.size();
  for (const auto& invalid : invalids) {
    NSData* bytes = [NSData dataWithBytes:invalid.data() length:invalid.size()];
    rejects([&] { session.receive(json(part(bytes))); });
  }
  require(session.events.size() == before);
}
int main() { @autoreleasepool {
  try {
    scriptIssueTests();
    scriptIssueTransferTests();
    scriptIssueRawUnicodeTests();
    require(sceneRoute("__runtime/index.html", "GET", false).mount == SceneMount::runtime);
    require(sceneRoute("__project/scene.pkg", "GET", false).path == "scene.pkg");
    require(sceneRoute("__scene/config", "GET", true).mount == SceneMount::config);
    require(sceneRoute("__scene/spectrum", "GET", true).mount == SceneMount::spectrum);
    rejects([] { sceneRoute("__scene/spectrum", "POST", true); });
    rejects([] { sceneRoute("__scene/spectrum", "GET", false); });
    require(sceneRoute("__scene/event", "POST", true).mount == SceneMount::event);
    for (auto path : {"index.html", "__project/../secret", "__runtime/./index.html", "__project//x", "__project/", "__scene/config/x"})
      rejects([&] { sceneRoute(path, "GET", true); });
    rejects([] { sceneRoute("__scene/event", "POST", false); });
    rejects([] { sceneRoute("__scene/event", "GET", true); });
    rejects([] { sceneRoute("__project/x", "POST", true); });
    auto ready = parseSceneEvent(R"({"type":"ready","sceneID":"scene","generation":7,"frame":1})", "scene", 7);
    require(ready.type == "ready");
    for (auto body : {R"({"type":"ready","sceneID":"scene","generation":6,"frame":1})",
                     R"({"type":"ready","sceneID":"other","generation":7,"frame":1})",
                     R"({"type":"ready","sceneID":"scene","generation":7,"frame":true})",
                     R"({"type":"ready","sceneID":"scene","generation":7,"frame":0})",
                     R"({"type":"ready","sceneID":"scene","generation":7,"frame":1,"extra":0})",
                     R"({"type":"command-ack","sceneID":"scene","generation":7,"commandID":""})", "[]", "invalid"})
      rejects([&] { parseSceneEvent(body, "scene", 7); });
    require(parseSceneEvent(R"({"type":"command-ack","sceneID":"scene","generation":7,"commandID":"abc"})", "scene", 7).commandID == "abc");
    require(parseSceneEvent(R"({"type":"error","sceneID":"scene","generation":7,"message":"actual engine failure"})", "scene", 7).message == "actual engine failure");
    rejects([] { parseSceneEvent(R"({"type":"error","sceneID":"scene","generation":7,"message":"bad\u0000message"})", "scene", 7); });
    rejects([] { parseSceneEvent(std::string(8193, ' '), "scene", 7); });
    SceneSession session("scene", 7, "{}");
    std::vector<double> bands(64, 0.25);
    require(session.replaceSpectrum(bands, bands));
    require(session.spectrumJSON().value().find("0.25") != std::string::npos);
    rejects([&] { session.replaceSpectrum(std::vector<double>(63), bands); });
    rejects([&] { session.replaceSpectrum(std::vector<double>(64, 1.1), bands); });
    rejects([&] { session.replaceSpectrum(std::vector<double>(64, NAN), bands); });
    session.receive(R"({"type":"ready","sceneID":"scene","generation":7,"frame":1})");
    require(session.events.size() == 1);
    rejects([&] { session.receive(R"({"type":"ready","sceneID":"scene","generation":8,"frame":1})"); });
    require(session.events.size() == 1);
    session.retired = true;
    require(!session.replaceSpectrum(bands, bands));
    require(!session.spectrumJSON().has_value());
    require(!session.receive(R"({"type":"ready","sceneID":"scene","generation":7,"frame":1})"));
    require(session.events.size() == 1);
    char pattern[] = "/tmp/dw-scene-routes-XXXXXX";
    const std::filesystem::path base(mkdtemp(pattern));
    std::filesystem::create_directories(base / "runtime"); std::filesystem::create_directories(base / "project");
    std::ofstream(base / "runtime/index.html") << "trusted";
    std::ofstream(base / "project/index.html") << "untrusted";
    std::filesystem::create_symlink(base / "runtime/index.html", base / "project/escape");
    ProjectFiles runtime((base / "runtime").string(), [](auto&) {}), project((base / "project").string(), [](auto&) {});
    auto route = sceneRoute("__runtime/index.html", "GET", true);
    auto resource = (route.mount == SceneMount::runtime ? runtime : project).open(route.path);
    char data[8]{}; require(read(resource.descriptor(), data, 7) == 7 && std::string(data) == "trusted"); resource.close();
    rejects([&] { project.open(sceneRoute("__project/escape", "GET", true).path); });
    std::filesystem::remove_all(base);
    std::cout << "scene protocol and descriptor mount tests passed\n";
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
} }
