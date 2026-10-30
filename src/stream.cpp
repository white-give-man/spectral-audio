#include "spectral_cpu.h"
#include "predictor.hpp"
#include "model_data.hpp"
#include <array>
#include <complex>
#include <cmath>
#include <algorithm>
#include <new>
struct spectral_stream {
    int channels; bool unity;
    double strength = 1., target_strength = 1.;
    std::array<spectral::GainPredictor,2> models;
    std::array<double,1024> window{};
    std::array<std::complex<double>,512> twiddle{};
    std::array<std::array<double,512>,2> previous{},overlap{};
    std::array<double,512> previous_norm{};
    spectral_stream(int ch,bool u):channels(ch),unity(u) {
        const double pi=std::acos(-1.);
        for(int i=0;i<1024;++i) window[i]=.5-.5*std::cos(2*pi*i/1023.);
        for(int i=0;i<512;++i) twiddle[i]=std::polar(1.,-2*pi*i/1024.);
    }
    void reset() noexcept {
        strength = target_strength;
        for(auto& m:models)m.reset();
        for(auto& v:previous)v.fill(0);
        for(auto& v:overlap)v.fill(0);
        previous_norm.fill(0);
    }
    void fft(std::array<std::complex<double>,1024>& x,bool inverse) noexcept {
        for(unsigned i=1,j=0;i<1024;++i) {
            unsigned bit=512;
            for(;j&bit;bit>>=1)j^=bit;
            j^=bit;if(i<j)std::swap(x[i],x[j]);
        }
        for(int len=2;len<=1024;len<<=1) {
            const int half=len/2,step=1024/len;
            for(int base=0;base<1024;base+=len)for(int i=0;i<half;++i) {
                const auto w=inverse?std::conj(twiddle[i*step]):twiddle[i*step];
                const auto a=x[base+i],b=x[base+i+half]*w;
                x[base+i]=a+b;x[base+i+half]=a-b;
            }
        }
        if(inverse)for(auto& v:x)v/=1024.;
    }
    bool process(const float* input,float* output) noexcept {
        using namespace spectral::weights;
        std::array<std::array<double,512>,2> current{};
        for(int i=0;i<512;++i)for(int ch=0;ch<channels;++ch) {
            const float v=input[i*channels+ch];
            if(!std::isfinite(v)||v < -1 || v > 1)return false;
            current[ch][i]=double(v)*32768.;
        }
        // Ramp over at most ten hops (~107 ms), shared by both channels.
        strength += std::clamp(target_strength-strength, -.1, .1);
        for(int ch=0;ch<channels;++ch) {
            std::array<std::complex<double>,1024> spectrum{};
            for(int i=0;i<512;++i) {
                spectrum[i]=previous[ch][i]*window[i];
                spectrum[512+i]=current[ch][i]*window[512+i];
            }
            fft(spectrum,false);
            double gains[513];
            if(unity)std::fill_n(gains,513,1.);
            else {
                double magnitude[513];float features[64],logs[64];double bands[64];
                for(int k=0;k<513;++k)magnitude[k]=std::abs(spectrum[k]);
                for(int i=0;i<64;++i) {
                    double sum=0;
                    for(int k=0;k<513;++k)sum+=analysis[i*513+k]*magnitude[k];
                    features[i]=float(sum);
                }
                models[ch].infer(features,logs);
                for(int i=0;i<64;++i) {
                    bands[i]=spectral::shaped_gain(double(logs[i]), strength);
                    if(!std::isfinite(bands[i]))return false;
                }
                for(int k=0;k<513;++k) {
                    double sum=0;
                    for(int i=0;i<64;++i)sum+=synthesis[k*64+i]*bands[i];
                    gains[k]=sum;
                }
            }
            for(int k=0;k<513;++k)spectrum[k]*=gains[k];
            for(int k=1;k<512;++k)spectrum[1024-k]=std::conj(spectrum[k]);
            fft(spectrum,true);
            for(int i=0;i<512;++i) {
                const double divisor=previous_norm[i]+window[i]*window[i];
                const double v=overlap[ch][i]+spectrum[i].real()*window[i];
                output[i*channels+ch]=float((divisor>0?v/divisor:0)/32768.);
                overlap[ch][i]=spectrum[512+i].real()*window[512+i];
            }
            previous[ch]=current[ch];
        }
        for(int i=0;i<512;++i)previous_norm[i]=window[512+i]*window[512+i];
        return true;
    }
};
extern "C" {
// Registry entry (game=2, level=4). Add new models here as they become available.
int spectral_model_available(int game,int level){return spectral::find_model(game,level)!=nullptr;}
spectral_stream* spectral_stream_create(int preset,int level,int channels,int unity) {
    if(!spectral_model_available(preset,level)||(channels!=1&&channels!=2)||(unity!=0&&unity!=1))return nullptr;
    auto* s=new(std::nothrow) spectral_stream(channels,unity!=0);
    if(s)for(auto& model:s->models)model.select(spectral::find_model(preset,level));
    return s;
}
void spectral_stream_destroy(spectral_stream* s){delete s;}
int spectral_stream_configure(spectral_stream* s,int preset,int level){
    const auto* model=spectral::find_model(preset,level);if(!s||!model)return -1;
    for(auto& channel:s->models)channel.select(model);
    return 0;
}
int spectral_stream_set_strength(spectral_stream* s,float strength){
    if(!s||!std::isfinite(strength)||strength<0||strength>1)return -1;
    s->target_strength=strength;return 0;
}
int spectral_stream_reset(spectral_stream* s){if(!s)return -1;s->reset();return 0;}
int spectral_stream_process(spectral_stream* s,const float* in,float* out){return !s||!in||!out||!s->process(in,out)?-1:0;}
}
