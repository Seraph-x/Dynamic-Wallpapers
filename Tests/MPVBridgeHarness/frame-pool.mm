#import <AppKit/AppKit.h>
#import "../../Sources/MPVBridge/MPVBridge.mm"
#include <cassert>
#include <thread>

int main() {
    @autoreleasepool {
        dw::FrameBufferPool pool;
        auto displayed = pool.acquire(4096);
        std::memset(displayed->bytes.get(), 1, displayed->size);
        for (int frame = 2; frame <= 1001; ++frame) {
            auto incoming = pool.acquire(4096);
            assert(incoming->bytes.get() != displayed->bytes.get());
            std::memset(incoming->bytes.get(), frame % 255, incoming->size);
            assert(displayed->bytes[0] == (frame - 1) % 255);
            displayed = std::move(incoming);
        }
        assert(pool.allocationCount() == 2);
        fprintf(stderr, "MPV_POOL frames=1001 allocations=%zu previous_allocations=1001\n", pool.allocationCount());

        // NSData/CGDataProvider retain the actual lease, beyond delivery acknowledgement.
        auto retained = pool.acquire(16);
        std::memset(retained->bytes.get(), 77, retained->size);
        void* original = retained->bytes.get();
        std::shared_ptr<dw::FrameBuffer> newer;
        @autoreleasepool {
        NSData* data = MPVPixelData(retained);
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        data = nil; retained.reset();
        newer = pool.acquire(16);
        assert(newer->bytes.get() != original);
        std::memset(newer->bytes.get(), 99, newer->size);
        CFDataRef snapshot = CGDataProviderCopyData(provider);
        assert(CFDataGetBytePtr(snapshot)[0] == 77);
        CFRelease(snapshot); CGDataProviderRelease(provider);
        } // Foundation autoreleased owners must also relinquish their lease.
        auto recycled = pool.acquire(16);
        assert(recycled->bytes.get() == original);

        // Old geometry leases remain valid but cannot populate the current idle slot.
        auto resized = pool.acquire(32);
        recycled.reset(); newer.reset(); displayed.reset();
        assert(pool.idleBytes() == 0);
        std::thread release([pixels = std::move(resized)]() mutable { pixels.reset(); });
        release.join();
        assert(pool.idleBytes() == 32);
        auto last = pool.acquire(32);
        pool.stop();
        assert(pool.idleBytes() == 0);
        last.reset();
        assert(pool.idleBytes() == 0);
        try { (void)pool.acquire(32); assert(false); } catch (const std::logic_error&) { }

        std::shared_ptr<dw::FrameBuffer> surviving;
        { dw::FrameBufferPool temporary; surviving = temporary.acquire(16); }
        surviving->bytes[0] = 42;
        surviving.reset();
        fprintf(stderr, "MPV_POOL ownership/resize/thread-release/shutdown PASS\n");
    }
}
