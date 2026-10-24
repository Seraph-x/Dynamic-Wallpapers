#import <Foundation/Foundation.h>
#include "SceneProtocol.hpp"
#include <cstdio>
#include <memory>
#include <stdexcept>
static void require(bool result) { if (!result) throw std::runtime_error("Editor protocol assertion failed"); }
int main() { @autoreleasepool {
  auto session = std::make_shared<dw::EditorSession>("session", 1, "{}");
  require(session->receive(R"({"type":"ready","session":"session","generation":1,"frame":1})"));
  require(session->receive(R"({"type":"dirty","session":"session","generation":1,"dirty":true})"));
  require(session->receive(R"({"type":"reply","session":"session","generation":1,"id":"command","payload":{"scene":{"future":1}}})"));
  require(session->receive(R"({"type":"resource","session":"session","generation":1,"id":"resource-1","action":"stage","data":"AQI="})"));
  require(session->receive(R"({"type":"resource","session":"session","generation":1,"id":"resource-2","action":"read","version":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"})"));
  require(session->receive(R"({"type":"resource","session":"session","generation":1,"id":"resource-3","action":"list"})"));
  for (const auto* body : {R"({"type":"ready","session":"other","generation":1,"frame":1})",
    R"({"type":"ready","session":"session","generation":true,"frame":1})",
    R"({"type":"ready","session":"session","generation":2,"frame":1})",
    R"({"type":"dirty","session":"session","generation":1,"dirty":1})",
    R"({"type":"reply","session":"session","generation":1,"id":"x","payload":[]})",
    R"({"type":"ready","session":"session","generation":1,"frame":0})",
    R"({"type":"ready","session":"session","generation":1,"frame":1,"extra":1})",
    R"({"type":"resource","session":"session","generation":1,"id":"x","action":"list","path":"../other"})",
    R"({"type":"resource","session":"session","generation":1,"id":"x","action":"stage","data":"bad!"})",
    R"({"type":"resource","session":"session","generation":1,"id":"x","action":"read","version":"../outside"})",
    R"({"type":"resource","session":"session","generation":1,"id":"x","action":"read","version":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":""})"}) {
      bool rejected = false; try { session->receive(body); } catch (const std::exception&) { rejected = true; }
      require(rejected);
  }
  { std::lock_guard lock(session->mutex); session->retired = true; session->events.clear(); }
  require(!session->receive(R"({"type":"dirty","session":"session","generation":1,"dirty":false})"));
  puts("Editor protocol: valid events, stale identities, malformed fields and retired sessions passed");
} }
