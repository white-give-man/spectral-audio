#include "predictor.hpp"
#include "model_data.hpp"
#include <algorithm>
#include <cmath>
namespace spectral {
void GainPredictor::infer(const float* features,float* output) noexcept {
    const auto& p=*parameters_;
    float x[64],gi[384],gh[384],next[128];
    for(int j=0;j<64;++j) x[j]=std::clamp((features[j]-p.mean[j])/p.std[j],-10.f,10.f);
    for(int i=0;i<384;++i) {
        float a=p.bias_ih[i],b=p.bias_hh[i];
        for(int j=0;j<64;++j) a+=p.weight_ih[i*64+j]*x[j];
        for(int j=0;j<128;++j) b+=p.weight_hh[i*128+j]*state_[j];
        gi[i]=a;gh[i]=b;
    }
    for(int i=0;i<128;++i) {
        const float r=1.f/(1.f+std::exp(-(gi[i]+gh[i])));
        const float z=1.f/(1.f+std::exp(-(gi[128+i]+gh[128+i])));
        const float n=std::tanh(gi[256+i]+r*gh[256+i]);
        next[i]=n+z*(state_[i]-n);
    }
    std::copy_n(next,128,state_.begin());
    for(int i=0;i<64;++i) {
        float v=p.head_bias[i];
        for(int j=0;j<128;++j) v+=p.head_weight[i*128+j]*state_[j];
        output[i]=v;
    }
}
}
