#pragma once
#include <cstdint>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

namespace dw {
enum class SceneMount { runtime, project, config, event, spectrum };
struct SceneRoute { SceneMount mount; std::string path; };
struct SceneScriptIssuePart {
  std::string transferID, bytes;
  uint64_t ordinal;
  bool final;
};
struct SceneEvent {
  std::string type, message, commandID, payload;
  std::optional<SceneScriptIssuePart> issuePart;
};
SceneRoute sceneRoute(const std::string& path, const std::string& method, bool mainFrame);
SceneEvent parseSceneEvent(const std::string& body, const std::string& sceneID, uint64_t generation);
struct EditorEvent { std::string type, id, payload; bool dirty = false; };
/// Editor has its own process and protocol; scene playback events remain unchanged.
struct EditorSession final {
  const std::string session, configuration;
  const uint64_t generation;
  std::mutex mutex;
  bool retired = false;
  std::vector<EditorEvent> events;
  EditorSession(std::string id, uint64_t revision, std::string config)
      : session(std::move(id)), configuration(std::move(config)), generation(revision) {}
  bool receive(const std::string& body);
};
/// Immutable identity/configuration; event queue is shared between CEF IO and UI.
struct SceneSession final {
  const std::string sceneID, configuration;
  const uint64_t generation;
  std::mutex mutex;
  bool retired = false;
  std::vector<SceneEvent> events;
  std::string spectrum;
  SceneSession(std::string id, uint64_t value, std::string json)
      : sceneID(std::move(id)), configuration(std::move(json)), generation(value) {}
  bool replaceSpectrum(const std::vector<double>& left, const std::vector<double>& right);
  std::optional<std::string> spectrumJSON();
  /// A valid in-flight event may finish after close cancelled its command.
  /// Return false so the caller records cancellation without reviving the page.
  bool receive(const std::string& body);
  void retire();
 private:
  struct IssueTransfer {
    std::string id, bytes;
    uint64_t nextOrdinal = 0;
  };
  std::optional<IssueTransfer> issueTransfer;
  std::unordered_set<std::string> completedIssueTransfers;
};
}  // namespace dw
