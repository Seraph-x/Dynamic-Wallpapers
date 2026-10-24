#include "SceneProtocol.hpp"
#include "LocalProjectFiles.hpp"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>
using namespace dw;
static void require(bool value) { if (!value) throw std::runtime_error("scene protocol assertion failed"); }
template<class F> static void rejects(F action) { bool failed = false; try { action(); } catch (...) { failed = true; } require(failed); }
int main() { @autoreleasepool {
  try {
    require(sceneRoute("__runtime/index.html", "GET", false).mount == SceneMount::runtime);
    require(sceneRoute("__project/scene.pkg", "GET", false).path == "scene.pkg");
    require(sceneRoute("__scene/config", "GET", true).mount == SceneMount::config);
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
    session.receive(R"({"type":"ready","sceneID":"scene","generation":7,"frame":1})");
    require(session.events.size() == 1);
    rejects([&] { session.receive(R"({"type":"ready","sceneID":"scene","generation":8,"frame":1})"); });
    require(session.events.size() == 1);
    session.retired = true;
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
