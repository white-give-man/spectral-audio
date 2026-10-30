#include "model_registry.hpp"
#include "model_data.hpp"
namespace spectral {
const ModelData* find_model(int game,int level) noexcept {
    static const ModelData* const slots[5][5] = {
        {nullptr,nullptr,nullptr,nullptr,nullptr},
        {nullptr,nullptr,nullptr,nullptr,nullptr},
        {nullptr,nullptr,nullptr,nullptr,&weights::predictor},
        {nullptr,nullptr,nullptr,nullptr,nullptr},
        {nullptr,nullptr,nullptr,nullptr,nullptr}
    };
    return game>=0 && game<5 && level>=0 && level<5 ? slots[game][level] : nullptr;
}
}
