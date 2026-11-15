#pragma once
#include <array>
#include <cmath>
#include <cstddef>

namespace spectral {
// Stereo-linked feed-forward peak compressor for 48 kHz float audio.
// Mode 0 disables compression; 1 is the default curve, 2..5 numbered curves.
class Dynamics {
public:
    Dynamics() noexcept {
        for (std::size_t i = 0; i < presets_.size(); ++i) {
            const auto& preset = presets_[i];
            quiet_peak_[i] = std::pow(10., (preset.threshold_db - knee_db / 2) / 20);
            release_step_[i] = smoothing_step(preset.release_ms);
        }
    }

    void configure(unsigned mode) noexcept {
        if (mode != mode_) { mode_ = mode; transition_ = 128; }
    }
    void reset() noexcept { reduction_db_ = 0; gain_ = 1; transition_ = 0; }
    bool active() const noexcept { return mode_ != 0 || transition_ != 0; }

    double gain(double peak) noexcept {
        double target = 1;
        if (mode_) {
            const auto index = mode_ - 1;
            const double required_db = peak > quiet_peak_[index]
                ? static_reduction(20 * std::log10(peak), presets_[index]) : 0;
            const double step = required_db > reduction_db_ ? attack_step_ : release_step_[index];
            reduction_db_ += step * (required_db - reduction_db_);
            // Settle exactly at unity once the release tail is below 0.001 dB.
            if (required_db == 0 && reduction_db_ < .001) reduction_db_ = 0;
            if (reduction_db_ != 0) target = std::exp(-reduction_db_ * log_amplitude_per_db);
        }
        // Fade control changes separately from the attack of the compressor.
        if (transition_) { gain_ += (target - gain_) / transition_; --transition_; }
        else gain_ = target;
        return gain_;
    }

private:
    struct Preset {
        double threshold_db, ratio, release_ms;
    };
    // Thresholds and ratios target peak suppression in gameplay recordings.
    // Keep makeup gain at 0 dB so quiet material remains at its original level.
    static constexpr std::array<Preset, 5> presets_{{
        {-14, 1.50, 60},
        {-15, 1.75, 65},
        {-16, 2.25, 70},
        {-17, 3.00, 80},
        {-18, 4.00, 90},
    }};
    static constexpr double knee_db = 4;
    static constexpr double attack_ms = .08;
    static constexpr double log_amplitude_per_db = .11512925464970229; // ln(10) / 20
    static double smoothing_step(double ms) noexcept {
        return -std::expm1(-1. / (48 * ms));
    }
    // Quadratic soft knee in dB from Giannoulis, Massberg and Reiss (JAES, 2012).
    static double static_reduction(double level_db, const Preset& preset) noexcept {
        const double offset = level_db - preset.threshold_db;
        const double slope = 1 - 1 / preset.ratio;
        if (offset >= knee_db / 2) return slope * offset;
        const double above_knee_start = offset + knee_db / 2;
        return slope * above_knee_start * above_knee_start / (2 * knee_db);
    }

    std::array<double, presets_.size()> quiet_peak_{}, release_step_{};
    const double attack_step_ = smoothing_step(attack_ms);
    unsigned mode_ = 0, transition_ = 0;
    double reduction_db_ = 0, gain_ = 1;
};
} // namespace spectral
