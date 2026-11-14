#include "WebFrameStorage.hpp"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

int main() {
    dw::WebFrameStorage storage;
    constexpr int width = 128, height = 128;
    std::vector<std::uint8_t> source(width * height * 4, 11);
    auto displayed = storage.copy(source.data(), width, height, {{0, 0, width, height}});
    for (int frame = 2; frame <= 1001; ++frame) {
        for (int y = 0; y < 8; ++y) std::memset(source.data() + y * width * 4, frame % 255, 8 * 4);
        const auto oldPixels = std::vector<std::uint8_t>(displayed->bytes.get(), displayed->bytes.get() + displayed->size);
        auto incoming = storage.copy(source.data(), width, height, {{0, 0, 8, 8}});
        assert(std::memcmp(displayed->bytes.get(), oldPixels.data(), oldPixels.size()) == 0);
        assert(std::memcmp(incoming->bytes.get(), source.data(), source.size()) == 0);
        displayed = std::move(incoming);
    }
    const auto measured = storage.statistics();
    assert(measured.allocations == 2);
    assert(measured.copiedBytes == source.size() * 2 + 999 * 8 * 8 * 4);
    fprintf(stderr, "WEB_FRAME frames=1001 allocations=%zu copiedBytes=%zu previousCopiedBytes=%zu\n",
        measured.allocations, measured.copiedBytes, source.size() * 1001);

    // Moving damage must include changes missed while a buffer was retained.
    auto held = displayed;
    const auto heldPixels = std::vector<std::uint8_t>(held->bytes.get(), held->bytes.get() + held->size);
    for (int x = 0; x < 32; ++x) {
        source[(20 * width + x) * 4] = 99;
        auto next = storage.copy(source.data(), width, height, {{x, 20, 1, 1}});
        assert(std::memcmp(next->bytes.get(), source.data(), source.size()) == 0);
        displayed = std::move(next);
    }
    assert(std::memcmp(held->bytes.get(), heldPixels.data(), heldPixels.size()) == 0);
    displayed.reset();
    auto unchanged = storage.copy(source.data(), width, height, {});
    assert(std::memcmp(unchanged->bytes.get(), source.data(), source.size()) == 0);
    unchanged.reset();
    const auto before = storage.statistics().copiedBytes;
    unchanged = storage.copy(source.data(), width, height, {});
    assert(storage.statistics().copiedBytes == before);
    for (const auto rect : {dw::FrameRect{-1, 0, 1, 1}, dw::FrameRect{127, 0, 2, 1}}) {
        try { (void)storage.copy(source.data(), width, height, {rect}); assert(false); }
        catch (const std::invalid_argument&) { }
    }
    try { (void)storage.copy(nullptr, width, height, {}); assert(false); }
    catch (const std::invalid_argument&) { }
    auto resized = storage.copy(source.data(), 64, 128, {{1, 1, 1, 1}});
    assert(std::memcmp(resized->bytes.get(), source.data(), resized->size) == 0);
    assert(std::memcmp(held->bytes.get(), heldPixels.data(), heldPixels.size()) == 0);
    std::thread release([pixels = std::move(held)]() mutable { pixels.reset(); });
    release.join();
    storage.stop();
    assert(resized->bytes[0] == source[0]);
    try { (void)storage.copy(source.data(), width, height, {}); assert(false); }
    catch (const std::logic_error&) { }
    dw::WebFrameStorage changingSize;
    std::vector<std::uint8_t> square(64, 1);
    auto oldSquare = changingSize.copy(square.data(), 4, 4, {});
    std::fill(square.begin(), square.end(), 2);
    auto rectangle = changingSize.copy(square.data(), 2, 8, {});
    std::fill(square.begin(), square.end(), 3);
    auto newSquare = changingSize.copy(square.data(), 4, 4, {{0, 0, 1, 1}});
    oldSquare.reset();
    auto reusedSquare = changingSize.copy(square.data(), 4, 4, {});
    assert(std::memcmp(reusedSquare->bytes.get(), square.data(), square.size()) == 0);
    fprintf(stderr, "WEB_FRAME damage/immutability/resize/thread-release/close PASS\n");
}
