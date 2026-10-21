#include "source-outcome.hpp"
#include <iostream>

int main() {
  SourceState state;
  state.loaded = state.greenPaint = state.closed = state.clientDestroyed = true;
  state.result = "fixture-result";
  if (!state.passed(true, true)) return 1;
  // Same state mutation made by OnRenderProcessTerminated/SOURCE_FAILURE during closing.
  state.failed = true;
  if (state.passed(true, true)) {
    std::cerr << "SOURCE_OUTCOME ERROR late failure became final success\n";
    return 1;
  }
  std::cout << "SOURCE_OUTCOME passed late-failure propagation\n";
  return 0;
}
