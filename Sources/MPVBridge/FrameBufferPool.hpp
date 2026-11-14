#pragma once
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <stdexcept>

namespace dw {
struct FrameBuffer {
    explicit FrameBuffer(std::size_t length) : bytes(std::make_unique<std::uint8_t[]>(length)), size(length) {}
    std::unique_ptr<std::uint8_t[]> bytes;
    const std::size_t size;
};

/// A lease returns storage only when the final pixel consumer releases it, on any queue.
class FrameBufferPool {
    struct State {
        std::mutex mutex;
        std::unique_ptr<FrameBuffer> idle;
        std::size_t size = 0, allocations = 0;
        bool stopped = false;
    };
    const std::shared_ptr<State> state_ = std::make_shared<State>();
public:
    std::shared_ptr<FrameBuffer> acquire(std::size_t size) {
        std::unique_ptr<FrameBuffer> buffer;
        {
            std::lock_guard<std::mutex> lock(state_->mutex);
            if (state_->stopped || size == 0) throw std::logic_error("Frame pool is stopped or size is zero");
            if (state_->size != size) { state_->idle.reset(); state_->size = size; }
            buffer = std::move(state_->idle);
            if (!buffer) { buffer = std::make_unique<FrameBuffer>(size); ++state_->allocations; }
        }
        // Construct the shared control block outside the lock: allocation failure
        // invokes its deleter, which must be able to return the unique buffer.
        return {buffer.release(), [weak = std::weak_ptr<State>(state_)](FrameBuffer* pointer) {
            std::unique_ptr<FrameBuffer> returned(pointer);
            if (const auto state = weak.lock()) {
                std::lock_guard<std::mutex> lock(state->mutex);
                // Keep just the next producer's reusable allocation; all live frames
                // remain independently owned by consumers, without a frame-count cap.
                if (!state->stopped && state->size == returned->size && !state->idle)
                    state->idle = std::move(returned);
            }
        }};
    }

    void stop() {
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->stopped = true; state_->idle.reset();
    }
    std::size_t allocationCount() const {
        std::lock_guard<std::mutex> lock(state_->mutex); return state_->allocations;
    }
    std::size_t idleBytes() const {
        std::lock_guard<std::mutex> lock(state_->mutex); return state_->idle ? state_->idle->size : 0;
    }
};
}
