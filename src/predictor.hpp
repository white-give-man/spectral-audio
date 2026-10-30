#pragma once
#include <array>
#include <cmath>
#include "model_registry.hpp"
namespace spectral {
// Positive log gain controls enhancement; negative gain retains masking attenuation.
inline double shaped_gain(double log_gain, double strength) noexcept {
    return std::exp(log_gain > 0 ? log_gain * strength : log_gain);
}
class GainPredictor {
    std::array<float,128> state_{};
    const ModelData* parameters_ = find_model(2,4);
public:
    void select(const ModelData* parameters) noexcept { if(parameters_ != parameters) {parameters_=parameters;reset();} }
    void reset() noexcept {state_.fill(0);}
    void infer(const float* features, float* log_gains) noexcept;
};
}
