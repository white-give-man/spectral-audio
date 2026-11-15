#include "runtime.hpp"
#include "processor.hpp"
#include <tlhelp32.h>
#include <iostream>
#include <map>
#include <cstdlib>
#include <cerrno>

static std::string json(const wchar_t* s) {
    std::string out="\"";
    for(;*s;++s) {
        if(*s==L'"' || *s==L'\\') {out+='\\';out+=char(*s);}
        else if(*s>=32 && *s<127) out+=char(*s);
        else {char b[8];sprintf_s(b,"\\u%04x",unsigned(*s));out+=b;}
    }
    return out+'"';
}
int wmain(int argc,wchar_t** argv) {
    using namespace spectralapo;
    if(argc==2 && wcscmp(argv[1],L"models")==0) {
        std::cout<<"[";
        for(int game=0;game<5;++game)for(int level=0;level<5;++level) {
            if(game||level)std::cout<<",";
            std::cout<<"{\"game\":"<<game<<",\"level\":"<<level<<",\"available\":"
                <<(spectral_model_available(game,level)?"true":"false")<<"}";
        }
        std::cout<<"]\n";return 0;
    }
    const bool create=argc==2 && wcscmp(argv[1],L"init")==0;
    const bool set=argc==3 && wcscmp(argv[1],L"set")==0;
    const bool status=argc==2 && wcscmp(argv[1],L"status")==0;
    const bool set_drc=argc==4 && wcscmp(argv[1],L"drc")==0;
    const bool has_frequencies=argc==3+2*Spectral_EQ_BANDS;
    const bool set_eq=(argc==3+Spectral_EQ_BANDS || has_frequencies) && wcscmp(argv[1],L"eq")==0;
    if(!create && !set && !status && !set_eq && !set_drc) {
        std::cerr<<"usage: spectral_apo_runtime models | init | status | set PACKED | drc ENABLED MODE(0..4) | eq ENABLED BAND1 ... BAND10 [HZ1 ... HZ10]\n";
        return 2;
    }
    Runtime runtime;
    const auto error=runtime.open(create||set||set_eq||set_drc,create);
    if(error) {std::cout<<"{\"error\":"<<error<<",\"instances\":[]}\n";return 1;}
    if(set) {
        errno=0;
        wchar_t* end=nullptr;const auto word=wcstoull(argv[2],&end,10);
        if(!*argv[2] || *end || errno==ERANGE || word>UINT32_MAX || (!Settings::unpack(uint32_t(word)).valid() || !spectral_model_available(int(Settings::unpack(uint32_t(word)).game),int(Settings::unpack(uint32_t(word)).level)))) return 2;
        InterlockedExchange(&runtime.data->settings,LONG(word));
        FlushViewOfFile(runtime.data,sizeof(RuntimeData));
    }
    if (set_drc) {
        if ((wcscmp(argv[2],L"0") && wcscmp(argv[2],L"1")) ||
            wcslen(argv[3])!=1 || argv[3][0]<L'0' || argv[3][0]>L'4') return 2;
        const auto code = argv[2][0]==L'1' ? unsigned(argv[3][0]-L'0')+1u : 0u;
        LONG before, after;
        do {
            before=runtime.data->settings;
            auto settings=Settings::unpack(uint32_t(before));
            settings.drc_mode=code;
            if (!settings.valid() || !spectral_model_available(int(settings.game),int(settings.level))) return 2;
            after=LONG(settings.pack());
        } while (InterlockedCompareExchange(&runtime.data->settings,after,before)!=before);
        if (!FlushViewOfFile(runtime.data,sizeof(RuntimeData))) return 1;
    }
    EqualizerSettings eq;
    if (set_eq) {
        if (wcscmp(argv[2],L"0") && wcscmp(argv[2],L"1")) return 2;
        eq.enabled = argv[2][0] == L'1';
        for (size_t i=0; i<eq.bands.size(); ++i) {
            wchar_t* end = nullptr;
            const auto value = wcstol(argv[3+i], &end, 10);
            if (end == argv[3+i] || *end || value < -600 || value > 600) return 2;
            eq.bands[i] = int(value);
        }
        if (has_frequencies) for (size_t i=0; i<eq.frequencies_hz.size(); ++i) {
            const auto* text = argv[3+Spectral_EQ_BANDS+i];
            wchar_t* end = nullptr;
            const auto hz = wcstol(text, &end, 10);
            if (end == text || *end || (hz && (hz < Spectral_EQ_MIN_HZ || hz > Spectral_EQ_MAX_HZ))) return 2;
            eq.frequencies_hz[i] = int(hz);
        }
        const auto result = runtime.write_equalizer(eq, has_frequencies);
        std::cout<<"{\"error\":"<<result<<",\"eq_revision\":"<<eq.revision<<"}\n";
        return result ? 1 : 0;
    }
    for (int attempt=0; attempt<8 && !runtime.read_equalizer(eq); ++attempt) {}
    std::map<DWORD,std::wstring> names;
    HANDLE snap=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
    if(snap!=INVALID_HANDLE_VALUE) {PROCESSENTRY32W p{};p.dwSize=sizeof(p);if(Process32FirstW(snap,&p)) do {names[p.th32ProcessID]=p.szExeFile;} while(Process32NextW(snap,&p));CloseHandle(snap);}
    const auto settings_word=uint32_t(runtime.data->settings);
    const auto settings=Settings::unpack(settings_word);
    std::cout<<"{\"error\":0,\"settings\":"<<settings_word<<",\"slots_used\":"<<runtime.data->next_slot
        <<",\"drc\":{\"enabled\":"<<(settings.drc_mode?"true":"false")<<",\"mode\":"<<(settings.drc_mode?settings.drc_mode-1:0)<<"}"
        <<",\"eq\":{\"enabled\":"<<(eq.enabled?"true":"false")<<",\"revision\":"<<eq.revision<<",\"bands\":[";
    for (size_t i=0; i<eq.bands.size(); ++i) std::cout<<(i?",":"")<<eq.bands[i];
    std::cout<<"],\"frequencies_hz\":[";
    for (size_t i=0; i<eq.frequencies_hz.size(); ++i) std::cout<<(i?",":"")<<eq.frequencies_hz[i];
    std::cout<<"]},\"instances\":[";
    bool comma=false;
    for(const auto& shared:runtime.data->slots) {
        RuntimeSlot s{};bool stable=false;
        for(int n=0;n<8;++n) {
            const auto before=shared.sequence;MemoryBarrier();
            if(before&1) continue;
            memcpy(&s,&shared,sizeof(s)); MemoryBarrier();
            if(before==shared.sequence) {stable=true;break;}
        }
        if(!stable || !s.pid) continue;
        if(comma) std::cout<<',';comma=true;
        std::cout<<"{\"pid\":"<<s.pid<<",\"instance\":"<<s.instance<<",\"process\":"<<json(names[s.pid].c_str())
            <<",\"module\":"<<json(s.module)<<",\"endpoint\":"<<json(s.endpoint)<<",\"stage\":"<<s.stage<<",\"hresult\":"<<DWORD(s.result)
            <<",\"unity\":"<<s.unity<<",\"raw\":"<<s.raw<<",\"discovery\":"<<s.discovery<<",\"locked\":"<<s.locked
            <<",\"init_bytes\":"<<s.init_bytes<<",\"rate\":"<<s.rate<<",\"channels\":"<<s.channels
            <<",\"eq_revision\":"<<s.eq_revision<<",\"settings\":"<<s.settings<<",\"callbacks\":"<<s.callbacks<<",\"frames\":"<<s.frames<<",\"faults\":"<<s.faults
            <<",\"max_callback_us\":"<<(s.frequency?double(s.max_ticks)*1e6/s.frequency:0)
            <<",\"age_ms\":"<<(GetTickCount64()-s.heartbeat)<<'}';
    }
    std::cout<<"]}\n";return 0;
}
