#pragma once
#include <cstdint>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace dw {
enum class SceneMount { runtime, project, config, event };
struct SceneRoute { SceneMount mount; std::string path; };
struct SceneEvent { std::string type, message, commandID; };
SceneRoute sceneRoute(const std::string& path, const std::string& method, bool mainFrame);
SceneEvent parseSceneEvent(const std::string& body, const std::string& sceneID, uint64_t generation);
/// Immutable identity/configuration; event queue is shared between CEF IO and UI.
struct SceneSession final {
  const std::string sceneID, configuration;
  const uint64_t generation;
  std::mutex mutex;
  bool retired = false;
  std::vector<SceneEvent> events;
  SceneSession(std::string id, uint64_t value, std::string json)
      : sceneID(std::move(id)), configuration(std::move(json)), generation(value) {}
  /// A valid in-flight event may finish after close cancelled its command.
  /// Return false so the caller records cancellation without reviving the page.
  bool receive(const std::string& body) {
    auto event = parseSceneEvent(body, sceneID, generation);
    std::lock_guard lock(mutex);
    if (retired) return false;
    events.push_back(std::move(event));
    return true;
  }
};
}  // namespace dw
