#include "runtime.hpp"
#include "processor.hpp"
#include <tlhelp32.h>
#include <iostream>
#include <map>
#include <cstdlib>

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
    if(!create && !set && !status) {std::cerr<<"usage: spectral_apo_runtime models | init | status | set PACKED\n";return 2;}
    Runtime runtime;
    const auto error=runtime.open(create||set,create);
    if(error) {std::cout<<"{\"error\":"<<error<<",\"instances\":[]}\n";return 1;}
    if(set) {
        wchar_t* end=nullptr;const auto word=wcstoul(argv[2],&end,10);
        if(!*argv[2] || *end || (!Settings::unpack(word).valid() || !spectral_model_available(int(Settings::unpack(word).game),int(Settings::unpack(word).level)))) return 2;
        InterlockedExchange(&runtime.data->settings,LONG(word));
        FlushViewOfFile(runtime.data,sizeof(RuntimeData));
    }
    std::map<DWORD,std::wstring> names;
    HANDLE snap=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
    if(snap!=INVALID_HANDLE_VALUE) {PROCESSENTRY32W p{};p.dwSize=sizeof(p);if(Process32FirstW(snap,&p)) do {names[p.th32ProcessID]=p.szExeFile;} while(Process32NextW(snap,&p));CloseHandle(snap);}
    std::cout<<"{\"error\":0,\"settings\":"<<DWORD(runtime.data->settings)<<",\"slots_used\":"<<runtime.data->next_slot<<",\"instances\":[";
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
            <<",\"settings\":"<<s.settings<<",\"callbacks\":"<<s.callbacks<<",\"frames\":"<<s.frames<<",\"faults\":"<<s.faults
            <<",\"max_callback_us\":"<<(s.frequency?double(s.max_ticks)*1e6/s.frequency:0)
            <<",\"age_ms\":"<<(GetTickCount64()-s.heartbeat)<<'}';
    }
    std::cout<<"]}\n";return 0;
}
