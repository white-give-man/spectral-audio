#pragma once
namespace spectral {
// Every future game/level model implements the same 64 -> GRU128 -> 64 contract.
// Parameters stay immutable; stream histories remain private to each channel.
struct ModelData {
    const float *weight_ih,*weight_hh,*bias_ih,*bias_hh,*head_weight,*head_bias,*mean,*std;
};
const ModelData* find_model(int game,int level) noexcept;
}
