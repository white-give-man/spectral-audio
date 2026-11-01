#pragma once
#include "spectral_single_clock.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>

namespace spectralapo {
// A single atomic word publishes a complete parameter snapshot. Only the audio
// thread touches DSP history. Model changes take effect at the next hop boundary.
struct Settings {
    unsigned game = 2, level = 4;
    bool bypass = false;
    unsigned gain_milli = 1000; // 0..1000; output is always limited to [-1,1].
    unsigned strength_milli = 1000; // 0..2000; independent of output volume.
    bool valid() const noexcept { return game < 5 && level < 5 && gain_milli <= 1000 && strength_milli <= 2000; }
    // Bit 27 marks explicit strength: low 10 bits in 17..26, high bit in 28.
    // Existing 0..100% words and the absent-marker default keep their wire identity.
    uint32_t pack() const noexcept {
        return (game & 3u) | ((game & 4u) << 13) | ((level & 3u) << 2) |
               ((level & 4u) << 14) | (unsigned(bypass) << 4) | (gain_milli << 5) |
               (strength_milli == 1000 ? 0u : (((strength_milli & 1023u) << 17) | ((strength_milli & 1024u) << 18) | (1u << 27)));
    }
    static Settings unpack(uint32_t v) noexcept {
        return {(v & 3u) | ((v >> 13) & 4u), ((v >> 2) & 3u) | ((v >> 14) & 4u),
                bool(v & 16), (v >> 5) & 1023u,
                (v & (1u << 27)) ? (((v >> 17) & 1023u) | ((v >> 18) & 1024u)) : 1000u};
    }
};

class Processor {
public:
    static constexpr size_t latency_frames = spectral::SingleClockCore::unity_delay_frames;
    static_assert(std::atomic<uint32_t>::is_always_lock_free, "RT settings require lock-free atomics");
    explicit Processor(Settings s = {}) : core_(int(s.game), int(s.level)), settings_(s.pack()) {
        if (!s.valid()) throw std::invalid_argument("Invalid APO settings");
        reset();
    }
    bool publish(Settings s) noexcept {
        if (!s.valid() || !spectral_model_available(int(s.game),int(s.level))) return false;
        settings_.store(s.pack(), std::memory_order_release);
        return true;
    }
    uint32_t applied_settings() const noexcept { return active_.pack(); }
    // Host calls only while stopped/unlocked.
    bool reset() noexcept {
        dry_.fill(0); phase_ = dry_pos_ = 0; failed_ = false;
        active_ = Settings::unpack(settings_.load(std::memory_order_acquire));
        mix_ = active_.bypass ? 0.f : 1.f;
        gain_ = active_.gain_milli / 1000.f;
        return core_.configure(int(active_.game), int(active_.level)) &&
            core_.set_strength(active_.strength_milli / 1000.f) && core_.reset();
    }
    // silent input may have a null/poisoned pointer and must never be read.
    // Silent callbacks still advance STFT history and emit pending audio tails.
    bool process(const float* in, float* out, size_t frames, bool silent, bool& output_silent) noexcept {
        output_silent = true;
        if ((!out || (!silent && !in)) && frames) return false;
        for (size_t f = 0; f < frames; ++f) {
            if (phase_ == 0) {
                const auto next = Settings::unpack(settings_.load(std::memory_order_acquire));
                if (next.game != active_.game || next.level != active_.level)
                    failed_ |= !core_.configure(int(next.game), int(next.level));
                failed_ |= !core_.set_strength(next.strength_milli / 1000.f);
                active_ = next;
            }
            float sample[2], wet[2], dry[2];
            for (size_t ch = 0; ch < 2; ++ch) {
                const float v = silent ? 0.f : in[2*f+ch];
                sample[ch] = std::isfinite(v) ? std::clamp(v, -1.f, 1.f) : 0.f;
                dry[ch] = dry_[2*dry_pos_+ch];
                dry_[2*dry_pos_+ch] = sample[ch];
            }
            failed_ |= !core_.process(sample, wet, 1);
            // Smooth user controls for 128 samples; keep the wet DSP running
            // in bypass so switching back does not restart model history.
            const float target = active_.bypass ? 0.f : 1.f;
            mix_ += std::clamp(target-mix_, -1.f/128, 1.f/128);
            const float target_gain = active_.gain_milli/1000.f;
            gain_ += std::clamp(target_gain-gain_, -1.f/128, 1.f/128);
            for (size_t ch = 0; ch < 2; ++ch) {
                // Preserve original arithmetic exactly at full wet/full gain.
                float v = mix_ == 1.f ? wet[ch] : mix_ == 0.f ? dry[ch]
                    : wet[ch]*mix_ + dry[ch]*(1.f-mix_);
                v *= gain_;
                if (failed_ || !std::isfinite(v)) v = 0;
                out[2*f+ch] = std::clamp(v, -1.f, 1.f);
                output_silent &= out[2*f+ch] == 0.f;
            }
            dry_pos_ = (dry_pos_+1) % latency_frames;
            phase_ = (phase_+1) % Spectral_HOP;
        }
        return !failed_;
    }
private:
    spectral::SingleClockCore core_;
    std::atomic<uint32_t> settings_;
    Settings active_{};
    std::array<float, latency_frames*2> dry_{};
    size_t phase_ = 0, dry_pos_ = 0;
    float mix_ = 1, gain_ = 1;
    bool failed_ = false;
};
} // namespace spectralapo
