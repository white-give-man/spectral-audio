#include "predictor.hpp"
#include "spectral_cpu.h"
#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif
extern "C" {
EXPORT void spectral_predict(const float* features,float* output,int frames) {
    spectral::GainPredictor model;
    for(int i=0;i<frames;++i)model.infer(features+64*i,output+64*i);
}
EXPORT int spectral_render_strength(const float* input,float* output,int hops,int unity,float strength) {
    auto* stream=spectral_stream_create(2,4,2,unity);
    if(!stream)return -1;
    if(spectral_stream_set_strength(stream,strength) || spectral_stream_reset(stream)) {spectral_stream_destroy(stream);return -1;}
    for(int i=0;i<hops;++i) {
        if(spectral_stream_process(stream,input+1024*i,output+1024*i)) {spectral_stream_destroy(stream);return -1;}
    }
    spectral_stream_destroy(stream);return 0;
}
EXPORT int spectral_render(const float* input,float* output,int hops,int unity) {
    return spectral_render_strength(input,output,hops,unity,1.f);
}

}
