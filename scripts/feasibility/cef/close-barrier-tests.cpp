#include "close-barrier.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <thread>

int main() {
  { CloseBarrier close;
    close.streamStarted(); close.requestClose(); close.browserClosed(); close.clientDestroyed();
    close.outputStopped(10, .02);
    assert(!close.resourcesReleased()); // Browser close does not end PCM lifetime.
    close.streamStopped();
    assert(close.resourcesReleased());
    assert(!close.presentationDeadlineReached(10.019));
    assert(close.presentationDeadlineReached(10.021));
  }
  { CloseBarrier close;
    close.requestClose(); close.browserClosed(); close.clientDestroyed(); close.outputStopped(0, 0);
    assert(close.resourcesReleased()); // A silent page need not start a stream.
    assert(close.presentationDeadlineReached(0));
  }
  { CloseBarrier close;
    close.streamStarted(); close.streamStopped(); close.streamStarted();
    close.requestClose(); close.browserClosed(); close.clientDestroyed(); close.outputStopped(0, 0);
    assert(!close.resourcesReleased());
    close.streamStopped(); assert(close.resourcesReleased());
  }
  { CloseBarrier close;
    close.callbackEntered(); close.requestClose(); close.browserClosed(); close.clientDestroyed();
    close.outputStopped(0, 0);
    assert(!close.resourcesReleased());
    close.callbackLeft(); assert(close.resourcesReleased());
  }
  { CloseBarrier close;
    close.requestClose(); close.audioError(); close.browserClosed(); close.clientDestroyed(); close.outputStopped(0, 0);
    assert(close.resourcesReleased());
    assert(close.errors() == 1); // Cleanup never erases a backend error.
  }
  { CloseBarrier close;
    close.requestClose(); close.browserClosed(); close.clientDestroyed();
    assert(!close.outputStopped(NAN, .02));
    assert(!close.outputStopped(10, -1));
    assert(!close.resourcesReleased());
  }
  { CloseBarrier close;
    close.streamStarted(); close.requestClose(); close.browserClosed(); close.clientDestroyed(); close.outputStopped(0, 0);
    std::thread callback([&] { close.callbackEntered(); close.audioError(); close.callbackLeft(); close.streamStopped(); });
    callback.join();
    assert(close.resourcesReleased()); assert(close.errors() == 1);
  }
  { CloseBarrier close;
    close.requestClose(); close.browserClosed(); close.outputStopped(0, 0);
    assert(!close.resourcesReleased());
    close.clientDestroyed(); assert(close.resourcesReleased());
  }
  std::puts("8 close barrier scenarios passed");
}
