#pragma once
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <unordered_set>
#include <vector>

namespace dw {
struct FrameRect { int x, y, width, height; };
struct WebFrame {
    WebFrame(int w, int h) : width(w), height(h), size(std::size_t(w) * h * 4),
        bytes(std::make_unique_for_overwrite<std::uint8_t[]>(size)), dirty(FrameRect{0, 0, w, h}) {}
    const int width, height;
    const std::size_t size;
    std::unique_ptr<std::uint8_t[]> bytes;
    std::optional<FrameRect> dirty; // Pool metadata; never used by pixel consumers.
};

/// Each allocation remembers damage since it was last written. A retained frame's
/// pixels stay immutable; only its accumulated damage metadata changes under the lock.
class WebFrameStorage {
public:
    struct Statistics { std::size_t allocations = 0, copiedBytes = 0; };
private:
    struct State {
        std::mutex mutex;
        std::unique_ptr<WebFrame> idle;
        std::unordered_set<WebFrame*> frames; // Observes both leased and idle allocations.
        int width = 0, height = 0;
        bool stopped = false;
        Statistics statistics;
    };
    const std::shared_ptr<State> state_ = std::make_shared<State>();

    static void addDamage(WebFrame& frame, const FrameRect& rect) {
        if (!frame.dirty) { frame.dirty = rect; return; }
        auto& previous = *frame.dirty;
        const int right = std::max(previous.x + previous.width, rect.x + rect.width);
        const int bottom = std::max(previous.y + previous.height, rect.y + rect.height);
        previous.x = std::min(previous.x, rect.x); previous.y = std::min(previous.y, rect.y);
        previous.width = right - previous.x; previous.height = bottom - previous.y;
    }

    static void validate(const void* source, int width, int height, const std::vector<FrameRect>& dirty) {
        if (!source || width <= 0 || height <= 0 ||
            std::size_t(width) > std::numeric_limits<std::size_t>::max() / 4 / std::size_t(height))
            throw std::invalid_argument("CEF supplied an invalid webpage frame");
        for (const auto& rect : dirty) {
            if (rect.x < 0 || rect.y < 0 || rect.width <= 0 || rect.height <= 0 ||
                rect.width > width || rect.height > height || rect.x > width - rect.width || rect.y > height - rect.height)
                throw std::invalid_argument("CEF supplied an invalid webpage damage rectangle");
        }
    }

public:
    std::shared_ptr<const WebFrame> copy(const void* source, int width, int height, const std::vector<FrameRect>& dirty) {
        validate(source, width, height, dirty);
        std::unique_ptr<WebFrame> frame;
        {
            std::lock_guard lock(state_->mutex);
            if (state_->stopped) throw std::logic_error("Webpage frame storage is closed");
            if (state_->width != width || state_->height != height) {
                if (state_->idle) state_->frames.erase(state_->idle.get());
                state_->idle.reset(); state_->width = width; state_->height = height;
                // Returning to an earlier size starts a new image history too.
                for (auto* existing : state_->frames)
                    existing->dirty = FrameRect{0, 0, existing->width, existing->height};
            }
            for (auto* existing : state_->frames)
                if (existing->width == width && existing->height == height)
                    for (const auto& rect : dirty) addDamage(*existing, rect);
            frame = std::move(state_->idle);
            if (!frame) {
                frame = std::make_unique<WebFrame>(width, height);
                state_->frames.insert(frame.get()); ++state_->statistics.allocations;
            }
            if (frame->dirty) {
                const auto rect = *frame->dirty;
                const std::size_t stride = std::size_t(width) * 4;
                for (int y = rect.y; y < rect.y + rect.height; ++y) {
                    const std::size_t offset = std::size_t(y) * stride + std::size_t(rect.x) * 4;
                    std::memcpy(frame->bytes.get() + offset, static_cast<const std::uint8_t*>(source) + offset,
                                std::size_t(rect.width) * 4);
                }
                state_->statistics.copiedBytes += std::size_t(rect.width) * rect.height * 4;
                frame->dirty.reset();
            }
        }
        // No base-image copy: the source is CEF's complete current bitmap.
        std::shared_ptr<WebFrame> lease(frame.release(), [weak = std::weak_ptr<State>(state_)](WebFrame* pointer) {
            std::unique_ptr<WebFrame> returned(pointer);
            if (const auto state = weak.lock()) {
                std::lock_guard lock(state->mutex);
                if (!state->stopped && pointer->width == state->width && pointer->height == state->height && !state->idle)
                    state->idle = std::move(returned);
                else state->frames.erase(pointer);
            }
        });
        return lease;
    }

    Statistics statistics() const { std::lock_guard lock(state_->mutex); return state_->statistics; }
    void stop() {
        std::lock_guard lock(state_->mutex);
        state_->stopped = true;
        if (state_->idle) state_->frames.erase(state_->idle.get());
        state_->idle.reset();
    }
};
}
