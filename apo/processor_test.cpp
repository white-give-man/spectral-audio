#include "processor.hpp"
#include "predictor.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

namespace {
bool track = false;
size_t allocations = 0;
void require(bool ok, const char* message) {
    if (!ok) { std::fprintf(stderr,"FAIL: %s\n",message); std::exit(1); }
}
}
void* operator new(size_t n) {
    if (track) ++allocations;
    if (auto p = std::malloc(n ? n : 1)) return p;
    throw std::bad_alloc();
}
void* operator new[](size_t n) { return ::operator new(n); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, size_t) noexcept { std::free(p); }
void operator delete[](void* p, size_t) noexcept { std::free(p); }

int main() {
    using namespace spectralapo;
    for (unsigned game=0; game<5; ++game) for (unsigned level=0; level<5; ++level) {
        const Settings settings{game,level,false,1000};
        const auto decoded = Settings::unpack(settings.pack());
        require(decoded.valid() && decoded.game==game && decoded.level==level && decoded.gain_milli==1000,
                "five-game five-level settings round trip");
    }
    require(Settings::unpack(97538).strength_milli == 1000 && Settings{}.pack() == 97538,
            "legacy settings retain full strength and wire identity");
    for (unsigned mode=0;mode<=5;++mode) for (unsigned strength: {0u,600u,1000u,2000u}) {
        const Settings value{2,4,false,735,strength,mode};
        const auto decoded=Settings::unpack(value.pack());
        require(decoded.valid() && decoded.drc_mode==mode && decoded.strength_milli==strength &&
            decoded.gain_milli==735 && decoded.game==2 && decoded.level==4,"DRC packing preserves every other control");
    }
    require(!Settings::unpack(Settings{}.pack() | (6u<<29)).valid() &&
        !Settings::unpack(Settings{}.pack() | (7u<<29)).valid(),"reserved DRC settings rejected");
    for (unsigned strength=0; strength<=2000; ++strength) {
        Settings s{2,4,false,735,strength};
        const auto d=Settings::unpack(s.pack());
        require(d.valid() && d.strength_milli==strength && d.gain_milli==735 && d.game==2 && d.level==4,
                "continuous strength and volume round trip independently");
        if (strength<=1000) {
            const uint32_t legacy_word = (Settings{2,4,false,735}.pack() & ~(1u << 27)) |
                (strength==1000 ? 0u : ((strength << 17) | (1u << 27)));
            require(s.pack()==legacy_word,"existing strength settings preserve wire identity");
        }
        const double amount=strength/1000.;
        require(std::abs(spectral::shaped_gain(std::log(16.),amount)-std::pow(16.,amount))<1e-12,
                "positive gains follow the continuous exponent curve");
        require(spectral::shaped_gain(std::log(.25),amount)==.25,
                "attenuation remains independent of enhancement strength");
    }
    auto* stream=spectral_stream_create(2,4,2,0);
    require(stream && spectral_stream_set_strength(stream,0)==0 && spectral_stream_set_strength(stream,1)==0 &&
            spectral_stream_set_strength(stream,2)==0,
            "strength endpoints accepted");
    require(spectral_stream_set_strength(stream,-.1f)!=0 && spectral_stream_set_strength(stream,2.001f)!=0 &&
            spectral_stream_set_strength(stream,std::numeric_limits<float>::quiet_NaN())!=0 &&
            spectral_stream_set_strength(nullptr,.5f)!=0,"invalid strength rejected");
    spectral_stream_destroy(stream);
    constexpr size_t frames = Spectral_HOP*32;
    std::vector<float> input(frames*2), reference(frames*2), result(frames*2);
    uint32_t random = 34567;
    for (auto& v : input) {
        random = random*1664525u+1013904223u;
        v = float(double(random)/4294967296.0-.5)*.00002f;
    }
    const std::vector<std::vector<size_t>> patterns = {
        {1},{48},{128},{144},{240},{480},{512},{1024},{7,1,480,128,1024,33}};
    size_t cases = 0;
    for (unsigned game=2;game<3;++game) for (unsigned level=4;level<5;++level) {
        spectral::SingleClockCore original{int(game),int(level)};
        require(original.process(input.data(),reference.data(),frames),"predictor DSP");
        for (const auto& pattern : patterns) for (bool alias : {false,true}) {
            Processor p({game,level,false,1000});
            result = alias ? input : std::vector<float>(frames*2);
            size_t at=0, block=0;
            while (at<frames) {
                const auto n = std::min(pattern[block++%pattern.size()],frames-at);
                bool silent = false;
                track = true;
                const auto ok = p.process((alias ? result.data() : input.data())+2*at,
                    result.data()+2*at,n,false,silent);
                track = false;
                require(ok && allocations == 0,"RT path: success and no C++ allocations");
                at+=n;
            }
            require(std::memcmp(result.data(),reference.data(),frames*2*sizeof(float)) == 0,
                "predictor DSP bit identity across callback sizes and aliasing");
            ++cases;
        }
    }
    // Silent input must flush queued samples instead of discarding a valid tail.
    Processor silent_path, zeros_path;
    std::vector<float> tail(4096), zero_tail(4096), zeros(4096);
    bool silent=false, other=false;
    require(silent_path.process(input.data(),result.data(),frames,false,silent),"prime silent path");
    require(zeros_path.process(input.data(),reference.data(),frames,false,other),"prime zero path");
    require(silent_path.process(nullptr,tail.data(),2048,true,silent),"null silent input");
    require(zeros_path.process(zeros.data(),zero_tail.data(),2048,false,other),"explicit zero input");
    require(tail == zero_tail && !silent,"silent buffer preserves pending tail exactly");
    require(silent_path.process(nullptr,tail.data(),2048,true,silent) && silent,"fully drained tail is silent");

    Processor dry({2,4,true,1000});
    require(dry.process(input.data(),result.data(),frames,false,silent),"delayed dry bypass");
    for (size_t f=0;f<frames;++f) for (size_t ch=0;ch<2;++ch)
        require(result[2*f+ch] == (f<Processor::latency_frames ? 0.f : input[2*(f-Processor::latency_frames)+ch]),
            "dry bypass has identical declared delay");
    require(dry.reset(),"reset");
    require(dry.process(input.data(),reference.data(),frames,false,silent) && reference == result,"reset replay identity");
    require(!dry.publish({5,0,false,1000}) && !dry.publish({0,5,false,1000}) &&
        !dry.publish({0,0,false,1001}) && !dry.publish({2,4,false,1000,2001}),"invalid configuration rejected");
    require(!dry.publish({0,0,false,1000}),"unavailable model rejected without changing audio state");
    require(!dry.process(nullptr,result.data(),1,false,silent),"invalid nonsilent input rejected");
    require(dry.process(nullptr,nullptr,0,true,silent),"empty callback");
    // Sanitization must protect the predictor DSP from NaN, infinity and overload.
    Processor sanitize({2,4,true,1000});
    input[0]=std::numeric_limits<float>::quiet_NaN();
    input[1]=std::numeric_limits<float>::infinity(); input[2]=4; input[3]=-4;
    require(sanitize.process(input.data(),result.data(),frames,false,silent),"sanitize anomalous PCM");
    require(result[2048]==0 && result[2049]==0 && result[2050]==1 && result[2051]==-1,"sanitized delayed values");
    for (float v : result) require(std::isfinite(v) && std::abs(v)<=1,"bounded finite output");
    input[0]=input[1]=input[2]=input[3]=0;
    // A control arriving partway through a hop is applied at the same sample
    // regardless of how the host divides the following callbacks.
    Processor a({2,4,false,1000,0}),b({2,4,false,1000,0});
    require(a.process(input.data(),result.data(),37,false,silent),"config prefix a");
    require(b.process(input.data(),reference.data(),37,false,silent),"config prefix b");
    require(a.publish({2,4,false,735,2000}) && b.publish({2,4,false,735,2000}),"publish control snapshot");
    require(a.process(input.data()+74,result.data()+74,frames-37,false,silent),"config suffix a");
    for (size_t f=37;f<frames;++f)
        require(b.process(input.data()+2*f,reference.data()+2*f,1,false,silent),"config suffix b");
    require(result == reference,"block-boundary strength/volume switching independent of fragmentation");
    require(a.reset() && b.reset(),"reset with 200 percent strength");
    require(a.process(input.data(),result.data(),frames,false,silent) &&
            b.process(input.data(),reference.data(),frames,false,other) && result==reference,
            "strength reset replay identity");
    Processor full, reduced({2,4,false,1000,600});
    require(full.process(input.data(),reference.data(),frames,false,other) &&
            reduced.process(input.data(),result.data(),frames,false,silent) && result!=reference,
            "strength reaches the model spectral path");
    // Verify the maximum strength through the packed APO settings and actual DSP.
    spectral::SingleClockCore maximum_core{2,4};
    require(maximum_core.set_strength(2.f) && maximum_core.reset(),"maximum core strength");
    Processor maximum({2,4,false,1000,2000});
    require(maximum_core.process(input.data(),reference.data(),frames),"maximum core render");
    track=true;
    const bool maximum_ok=maximum.process(input.data(),result.data(),frames,false,silent);
    track=false;
    require(maximum_ok && allocations==0,"maximum strength is allocation free");
    require(Settings::unpack(maximum.applied_settings()).strength_milli==2000,
            "maximum strength applied without truncation");
    for (size_t i=0;i<result.size();++i)
        require(std::isfinite(result[i]) && result[i]==std::clamp(reference[i],-1.f,1.f),
                "maximum APO strength matches the core with output limiting");
    // An exact-bin tone reaches the requested gain on both channels without
    // shifting latency. A second tone exercises the cut and filter independence.
    spectral::SingleClockCore flat_eq{2,4,true}, shaped_eq{2,4,true};
    int bands[Spectral_EQ_BANDS]{};
    bands[3]=600;
    bands[8]=-400;
    require(shaped_eq.set_eq(bands) && shaped_eq.reset(),"valid EQ reaches the core");
    bands[0]=601;
    require(!shaped_eq.set_eq(bands) && spectral_stream_set_eq(nullptr,nullptr)!=0,"invalid EQ rejected");
    for (size_t f=0; f<frames; ++f) {
        input[2*f]=float(.01*std::sin(2*std::acos(-1.)*11*f/1024));
        input[2*f+1]=float(.01*std::sin(2*std::acos(-1.)*171*f/1024));
    }
    require(flat_eq.process(input.data(),reference.data(),frames) &&
        shaped_eq.process(input.data(),result.data(),frames),"render EQ response");
    double amplitudes[2]{}, baseline[2]{};
    for (size_t f=4096; f<frames; ++f) for (size_t ch=0; ch<2; ++ch) {
        const double phase=2*std::acos(-1.)*(11+160*ch)*f/1024;
        amplitudes[ch]+=result[2*f+ch]*std::sin(phase);
        baseline[ch]+=reference[2*f+ch]*std::sin(phase);
    }
    require(amplitudes[0]/baseline[0]>1.90 && amplitudes[0]/baseline[0]<2.02 &&
        amplitudes[1]/baseline[1]>.62 && amplitudes[1]/baseline[1]<.65,
        "peaking EQ boosts near 500 Hz and cuts at 8 kHz");

    spectral::SingleClockCore moved_eq{2,4,true};
    int centers[Spectral_EQ_BANDS]{};
    bands[0]=0; bands[8]=0; centers[3]=8016;
    require(moved_eq.set_eq(bands, centers) && moved_eq.reset(),"move the 500 Hz band to 8016 Hz");
    centers[3]=20001;
    require(!moved_eq.set_eq(bands, centers),"reject out-of-range center");
    require(moved_eq.process(input.data(),result.data(),frames),"render moved center");
    double moved_amplitudes[2]{};
    for (size_t f=4096; f<frames; ++f) for (size_t ch=0; ch<2; ++ch) {
        const double phase=2*std::acos(-1.)*(11+160*ch)*f/1024;
        moved_amplitudes[ch]+=result[2*f+ch]*std::sin(phase);
    }
    require(moved_amplitudes[0]/baseline[0]>.99 && moved_amplitudes[0]/baseline[0]<1.02 &&
        moved_amplitudes[1]/baseline[1]>1.97 && moved_amplitudes[1]/baseline[1]<2.02,
        "boost follows the new center frequency");

    Processor eq_a, eq_b;
    require(eq_a.process(input.data(),result.data(),37,false,silent) &&
        eq_b.process(input.data(),reference.data(),37,false,silent),"prefix before live EQ change");
    EqualizerSettings eq;
    eq.enabled=true; eq.revision=7; eq.bands[4]=600; eq.frequencies_hz[4]=515;
    eq_a.publish_equalizer(eq); eq_b.publish_equalizer(eq);
    require(eq_a.applied_eq_revision()==0,"EQ defers application until next hop");
    track=true;
    const bool live_eq_ok=eq_a.process(input.data()+74,result.data()+74,frames-37,false,silent);
    track=false;
    require(live_eq_ok && allocations==0 && eq_a.applied_eq_revision()==7,"live EQ applies without allocating");
    for (size_t f=37; f<frames; ++f)
        require(eq_b.process(input.data()+2*f,reference.data()+2*f,1,false,silent),"fragmented EQ update");
    require(result==reference,"live EQ sample timing independent of callback fragmentation");
    Processor eq_bypass({2,4,true,1000},eq), flat_bypass({2,4,true,1000});
    require(eq_bypass.process(input.data(),result.data(),frames,false,silent) &&
        flat_bypass.process(input.data(),reference.data(),frames,false,silent) && result==reference,
        "restoring original sound bypasses model and EQ");

    std::printf("PASS EQ live updates, stereo response, and bypass\n");
    // Loud stereo input exercises compression, live controls, dry bypass and
    // tails across irregular callbacks, with the model and EQ both running.
    for (size_t f=0;f<frames;++f) {
        input[2*f]=float(.8*std::sin(2*std::acos(-1.)*11*f/1024));
        input[2*f+1]=input[2*f]*.25f;
    }
    eq.enabled=true; eq.bands.fill(0); eq.bands[3]=200;
    for (unsigned mode=1;mode<=5;++mode) {
        const Settings compressed{2,4,false,1000,1000,mode};
        Processor linked(compressed,eq),fragmented(compressed,eq),uncompressed({},eq);
        require(linked.process(input.data(),reference.data(),frames,false,silent),"DRC full-block model render");
        track=true;
        size_t at=0, block=0;
        const auto& pattern=patterns.back();
        while (at<frames) {
            const auto n=std::min(pattern[block++%pattern.size()],frames-at);
            require(fragmented.process(input.data()+2*at,result.data()+2*at,n,false,silent),"fragmented DRC render");
            at+=n;
        }
        track=false;
        require(allocations==0 && result==reference,"DRC fragmentation is exact and allocation free");
        result=input;
        require(fragmented.reset() && fragmented.process(result.data(),result.data(),frames,false,silent) &&
            result==reference,"DRC in-place and reset identity");
        require(uncompressed.process(input.data(),result.data(),frames,false,silent) && result!=reference,
            "DRC changes the model input/output");
        Processor bypassed({2,4,true,1000,1000,mode},eq);
        require(bypassed.process(input.data(),result.data(),frames,false,silent),"DRC dry bypass");
        for (size_t f=Processor::latency_frames;f<frames;++f)
            require(result[2*f]==input[2*(f-Processor::latency_frames)] &&
                result[2*f+1]==input[2*(f-Processor::latency_frames)+1],"original sound bypasses DRC too");
    }
    Processor live_a,live_b;
    require(live_a.process(input.data(),result.data(),37,false,silent) &&
        live_b.process(input.data(),reference.data(),37,false,silent),"DRC live prefix");
    require(live_a.publish({2,4,false,1000,1000,5}) && live_b.publish({2,4,false,1000,1000,5}),"enable live DRC");
    require(live_a.process(input.data()+74,result.data()+74,frames-37,false,silent),"DRC live suffix");
    for (size_t f=37;f<frames;++f)
        require(live_b.process(input.data()+2*f,reference.data()+2*f,1,false,silent),"DRC live fragmented suffix");
    require(result==reference && Settings::unpack(live_a.applied_settings()).drc_mode==5,
        "live DRC control applied at hop boundary");
    require(live_a.process(nullptr,tail.data(),2048,true,silent) &&
        live_b.process(zeros.data(),zero_tail.data(),2048,false,other) && tail==zero_tail,"DRC silent input preserves tails");
    require(live_a.process(nullptr,tail.data(),2048,true,silent) && silent,"DRC tail drains to silence");
    require(!live_a.publish({2,4,false,1000,1000,6}),"invalid DRC publication rejected");
    std::puts("PASS DRC realtime controls, allocation-free streaming, reset, tails and original sound");
    std::printf("PASS strength_values=2001 processor_cases=%zu streaming_bit_identity=1 latency_frames=%zu allocations=%zu\n",
        cases,Processor::latency_frames,allocations);
}
