#pragma once
#include "model_registry.hpp"
namespace spectral::weights {
extern const float gru_weight_ih_l0[24576];
extern const float gru_weight_hh_l0[49152];
extern const float gru_bias_ih_l0[384];
extern const float gru_bias_hh_l0[384];
extern const float head_weight[8192];
extern const float head_bias[64];
extern const float mean[64];
extern const float std[64];
extern const double analysis[32832];
extern const double synthesis[32832];
extern const ModelData predictor;
}
