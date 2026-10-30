#pragma once
#include "spectral_cpu.h"
#include <array>
#include <cstddef>
#include <memory>
#include <stdexcept>

namespace spectral {
// Fixed-capacity adapter for an in-process, equal-input/output-frame-count host.
// Stereo 48 kHz only. Device installation belongs to the host.
// The host owns the clock. There is no capture thread, clock correction,
// adaptive resampler, wait, or scheduling-jitter reservoir in this core.
class SingleClockCore {
public:
    static constexpr size_t adapter_padding_frames = Spectral_HOP;
    static constexpr size_t unity_delay_frames = 2*Spectral_HOP;

    explicit SingleClockCore(int game, int level, bool unity = false)
        : stream_(spectral_stream_create(game, level, 2, unity ? 1 : 0), spectral_stream_destroy) {
        if (!stream_) throw std::runtime_error("Cannot create Spectral core");
    }

    bool reset() noexcept {
        if (spectral_stream_reset(stream_.get())) return false;
        input_.fill(0); wet_.fill(0); fifo_.fill(0);
        fill_ = read_ = 0; count_ = adapter_padding_frames; failed_ = false;
        return true;
    }

    // Caller serializes this with process, at a DSP hop boundary.
    bool configure(int game, int level) noexcept {
        return spectral_stream_configure(stream_.get(), game, level) == 0;
    }

    bool set_strength(float strength) noexcept {
        return spectral_stream_set_strength(stream_.get(), strength) == 0;
    }

    // Supports identical input/output pointers. Normal path does not allocate.
    // The production host must implement format, silent-buffer, tail/drain,
    // configuration publication, bypass, gain and fault handling separately.
    bool process(const float* input, float* output, size_t frames) noexcept {
        if ((!input || !output) && frames) return false;
        for (size_t i = 0; i < frames; ++i) {
            input_[2*fill_] = input[2*i];
            input_[2*fill_+1] = input[2*i+1];
            if (++fill_ == Spectral_HOP) {
                if (failed_ || spectral_stream_process(stream_.get(), input_.data(), wet_.data())) {
                    failed_ = true; wet_.fill(0);
                }
                for (size_t j = 0; j < Spectral_HOP; ++j) {
                    const size_t at = (read_+count_) % capacity;
                    fifo_[2*at] = wet_[2*j]; fifo_[2*at+1] = wet_[2*j+1];
                    ++count_;
                }
                fill_ = 0;
            }
            output[2*i] = fifo_[2*read_]; output[2*i+1] = fifo_[2*read_+1];
            read_ = (read_+1) % capacity; --count_;
        }
        return !failed_;
    }
    size_t buffered_output_frames() const noexcept { return count_; }
private:
    static constexpr size_t capacity = 2*Spectral_HOP;
    std::unique_ptr<spectral_stream, decltype(&spectral_stream_destroy)> stream_;
    std::array<float, Spectral_HOP*2> input_{}, wet_{};
    std::array<float, capacity*2> fifo_{};
    size_t fill_ = 0, read_ = 0, count_ = adapter_padding_frames;
    bool failed_ = false;
};
} // namespace spectral
