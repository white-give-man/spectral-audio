#include "dynamics.hpp"
#include "spectral_single_clock.hpp"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <vector>

namespace {
void require(bool ok, const char* message) {
    if (!ok) { std::fprintf(stderr,"FAIL: %s\n",message); std::exit(1); }
}
}
int main() {
    // Independent steady-state expectations at half scale and full scale.
    constexpr double half[] = {0.7362240470346,0.6420728169709,0.5281951900505,0.4305464345656,0.3554450714553};
    constexpr double full[] = {0.5843414133735,0.4770582696144,0.3593813663805,0.2712272579332,0.2113489039837};
    for (unsigned mode=1; mode<=5; ++mode) {
        spectral::Dynamics dynamics;
        dynamics.configure(mode); dynamics.reset();
        for (int n=0; n<4096; ++n) require(dynamics.gain(.1)==1.,"quiet input has exact unity gain");
        double gain=1;
        for (int n=0; n<4096; ++n) gain=dynamics.gain(.5);
        require(std::abs(gain-half[mode-1])<1e-10,"half-scale static compression curve");
        for (int n=0; n<4096; ++n) gain=dynamics.gain(1.);
        require(std::abs(gain-full[mode-1])<1e-10,"full-scale static compression curve");
        const double released=dynamics.gain(.01);
        require(released>gain && released-gain<.001,"release preserves attenuation immediately after loud input");
        for (int n=0; n<48000; ++n) gain=dynamics.gain(.01);
        require(gain==1.,"release returns to unity on quiet input");
        dynamics.reset();
        require(dynamics.gain(1.)<.9,"attack catches the first full-scale sample");
        for (int n=1; n<16; ++n) gain=dynamics.gain(1.);
        require(std::abs(20*std::log10(gain/full[mode-1]))<.22,"attack reaches near steady state within 16 samples");
        for (int n=0; n<4096; ++n) gain=dynamics.gain(1.);
        dynamics.configure(0);
        const double fading=dynamics.gain(1.);
        require(fading>gain && fading-gain<.01,"disable fades instead of stepping");
        for (int n=0; n<128; ++n) gain=dynamics.gain(1.);
        require(gain==1.,"disabled mode settles to exact unity");
        dynamics.configure(mode); dynamics.reset();
        require(dynamics.gain(.001)==1.,"reset clears history and keeps mode");
    }
    spectral::Dynamics knee;
    knee.configure(1); knee.reset();
    require(knee.gain(std::pow(10., -17./20))==1.,"default soft knee leaves ordinary levels at unity");
    double mid_gain=1;
    for (int n=0; n<128; ++n) mid_gain=knee.gain(std::pow(10., -14./20));
    require(std::abs(20*std::log10(mid_gain)+1./6)<1e-9,"quadratic soft knee at the default threshold");

    auto* raw=spectral_stream_create(2,4,1,1);
    require(raw && spectral_stream_set_drc(raw,5)==0 && spectral_stream_set_drc(raw,6)!=0 &&
        spectral_stream_set_drc(nullptr,0)!=0,"validate DRC API");
    spectral_stream_destroy(raw);

    // No model and no EQ: a constant stereo signal must retain its channel
    // ratio, declared delay and the expected static gain through the STFT.
    constexpr size_t frames=16384;
    std::vector<float> input(frames*2), output(frames*2);
    for (size_t f=0; f<frames; ++f) { input[2*f]=.5f; input[2*f+1]=.125f; }
    spectral::SingleClockCore core(2,4,true);
    require(core.set_drc(1) && core.reset() && core.process(input.data(),output.data(),frames),"DRC through streaming core");
    for (size_t f=0; f<core.unity_delay_frames; ++f)
        require(std::abs(output[2*f])<1e-7 && std::abs(output[2*f+1])<1e-7,"DRC does not alter declared latency");
    require(output[2*core.unity_delay_frames]>.1f,"DRC onset occurs at declared latency");
    for (size_t f=8192; f<frames; ++f) {
        require(std::abs(output[2*f]-.5*half[0])<1e-6,"steady-state compression reaches output");
        require(output[2*f]==4*output[2*f+1],"stereo linking preserves channel ratio");
    }
    // Exercise the mono entry point separately from the stereo host adapter.
    raw=spectral_stream_create(2,4,1,1);
    float mono[Spectral_HOP], result[Spectral_HOP];
    std::fill_n(mono,Spectral_HOP,.5f);
    require(spectral_stream_set_drc(raw,5)==0 && spectral_stream_reset(raw)==0,"mono DRC setup");
    for (int n=0;n<20;++n) require(spectral_stream_process(raw,mono,result)==0,"mono DRC process");
    for (float v:result) require(std::abs(v-.5*half[4])<1e-6,"mono compression curve");
    spectral_stream_destroy(raw);
    std::puts("PASS DRC five curves, attack/release, smooth controls, stereo linking, mono and latency");
}
