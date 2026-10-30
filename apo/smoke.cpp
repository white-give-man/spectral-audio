#include <string>
#include "contract.hpp"
#include "processor.hpp"
#include <ks.h>
#include <ksmedia.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static void check(bool ok,const char* message) {
    if (!ok) { std::fprintf(stderr,"FAIL: %s (win32=%lu)\n",message,GetLastError()); std::exit(1); }
}
// A media-type test double: the DLL itself uses the real Windows APO ABI.
class Media final : public IAudioMediaType {
    ULONG refs_=1;
public:
    float rate=48000;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id,void** out) override {
        if (!out) return E_POINTER;
        *out=nullptr;
        if (id!=IID_IUnknown && id!=__uuidof(IAudioMediaType)) return E_NOINTERFACE;
        *out=this; AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override { return --refs_; }
    HRESULT STDMETHODCALLTYPE IsCompressedFormat(BOOL* b) override { if (!b) return E_POINTER; *b=FALSE; return S_OK; }
    HRESULT STDMETHODCALLTYPE IsEqual(IAudioMediaType*,DWORD*) override { return E_NOTIMPL; }
    const WAVEFORMATEX* STDMETHODCALLTYPE GetAudioFormat() override { return nullptr; }
    HRESULT STDMETHODCALLTYPE GetUncompressedAudioFormat(UNCOMPRESSEDAUDIOFORMAT* f) override {
        if (!f) return E_POINTER;
        *f={KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,2,4,32,rate,SPEAKER_FRONT_LEFT|SPEAKER_FRONT_RIGHT}; return S_OK;
    }
};

int main(int argc,char** argv) {
    using namespace spectralapo;
    check(argc==2,"usage: spectral_apo_smoke.exe path-to-SpectralAudio.dll");
    wchar_t temporary[MAX_PATH]{};check(GetTempPathW(MAX_PATH,temporary)!=0,"temporary directory");
    const auto isolated=std::wstring(temporary)+L"spectral-apo-smoke-"+std::to_wstring(GetCurrentProcessId())+L".bin";
    check(SetEnvironmentVariableW(L"SpectralAudio_TEST_RUNTIME",isolated.c_str())!=0,"isolate profile/runtime");
    check(SUCCEEDED(CoInitializeEx(nullptr,COINIT_MULTITHREADED)),"COM init");
    const auto dll=LoadLibraryA(argv[1]); check(dll!=nullptr,"load DLL");
    using GetFactory=HRESULT (WINAPI*)(REFCLSID,REFIID,void**);
    using CanUnload=HRESULT (WINAPI*)();
    const auto get=reinterpret_cast<GetFactory>(GetProcAddress(dll,"DllGetClassObject"));
    const auto unload=reinterpret_cast<CanUnload>(GetProcAddress(dll,"DllCanUnloadNow"));
    check(get && unload,"COM exports");
    for (const bool unity : {true,false}) {
        IClassFactory* factory=nullptr;
        check(SUCCEEDED(get(unity?clsid_unity:clsid_dsp,IID_IClassFactory,reinterpret_cast<void**>(&factory))),"class factory");
        check(unload()==S_FALSE,"factory prevents unload");
        IAudioProcessingObject* apo=nullptr;
        check(SUCCEEDED(factory->CreateInstance(nullptr,__uuidof(IAudioProcessingObject),reinterpret_cast<void**>(&apo))),"create APO");
        factory->Release();
        IAudioProcessingObjectConfiguration* config=nullptr;
        IAudioProcessingObjectRT* rt=nullptr; Control* control=nullptr;
        IAudioSystemEffects2* effects=nullptr;
        check(SUCCEEDED(apo->QueryInterface(__uuidof(IAudioProcessingObjectConfiguration),reinterpret_cast<void**>(&config))),"configuration interface");
        check(SUCCEEDED(apo->QueryInterface(__uuidof(IAudioProcessingObjectRT),reinterpret_cast<void**>(&rt))),"RT interface");
        check(SUCCEEDED(apo->QueryInterface(__uuidof(IAudioSystemEffects2),reinterpret_cast<void**>(&effects))),"system effects interface");
        check(SUCCEEDED(apo->QueryInterface(iid_control,reinterpret_cast<void**>(&control))),"control interface");
        APO_REG_PROPERTIES* reg=nullptr;
        check(SUCCEEDED(apo->GetRegistrationProperties(&reg)) && reg && reg->u32MinInputConnections==1 && reg->u32NumAPOInterfaces==1,"registration properties");
        CoTaskMemFree(reg);
        check(SUCCEEDED(apo->Initialize(0,nullptr)),"initialize for isolated host");
        check(apo->Initialize(0,nullptr)==APOERR_ALREADY_INITIALIZED,"double initialize");
        HNSTIME delay=-1;
        check(SUCCEEDED(apo->GetLatency(&delay)) && delay==(unity?0:213334),"honest GetLatency");
        GUID* ids=nullptr; UINT count=0;
        check(SUCCEEDED(effects->GetEffectsList(&ids,&count,nullptr)) && count==(unity?0u:1u),"effect discovery");
        CoTaskMemFree(ids);
        Media media;
        check(SUCCEEDED(apo->IsInputFormatSupported(nullptr,&media,nullptr)),"float32 stereo 48k");
        media.rate=44100;
        check(apo->IsInputFormatSupported(nullptr,&media,nullptr)==APOERR_FORMAT_NOT_SUPPORTED,"reject other sample rates");
        media.rate=48000;
        constexpr UINT32 max_frames=1024;
        APO_CONNECTION_DESCRIPTOR input_desc{APO_CONNECTION_BUFFER_TYPE_EXTERNAL,0,max_frames,&media,APO_CONNECTION_DESCRIPTOR_SIGNATURE};
        auto output_desc=input_desc;
        APO_CONNECTION_DESCRIPTOR* ins[]={&input_desc}; APO_CONNECTION_DESCRIPTOR* outs[]={&output_desc};
        check(config->LockForProcess(0,ins,1,outs)==APOERR_NUM_CONNECTIONS_INVALID,"validate connection count");
        check(SUCCEEDED(config->LockForProcess(1,ins,1,outs)),"lock for processing");
        check(config->LockForProcess(1,ins,1,outs)==APOERR_APO_LOCKED,"double lock");
        std::vector<float> input(8192),output(8192),expected(8192);
        for (size_t i=0;i<input.size();++i) input[i]=float(int(i%199)-99)*(argc==3 ? .008f : .0000001f);
        Processor reference;
        bool silent=false;
        check(reference.process(input.data(),expected.data(),4096,false,silent),"reference");
        const UINT32 blocks[]={1,48,128,144,240,480,512,1024};
        size_t at=0, block=0;
        while (at<4096) {
            const auto n=UINT32(std::min<size_t>(blocks[block++%8],4096-at));
            APO_CONNECTION_PROPERTY in{reinterpret_cast<UINT_PTR>(input.data()+2*at),n,BUFFER_VALID,APO_CONNECTION_PROPERTY_SIGNATURE};
            APO_CONNECTION_PROPERTY out{reinterpret_cast<UINT_PTR>(output.data()+2*at),0,BUFFER_INVALID,APO_CONNECTION_PROPERTY_SIGNATURE};
            APO_CONNECTION_PROPERTY* ip[]={&in}; APO_CONNECTION_PROPERTY* op[]={&out};
            check(rt->CalcInputFrames(n)==n && rt->CalcOutputFrames(n)==n,"equal frame mapping");
            rt->APOProcess(1,ip,1,op);
            check(out.u32ValidFrameCount==n && out.u32BufferFlags!=BUFFER_INVALID,"output frames/flags");
            at+=n;
        }
        check(output==(unity?input:expected),"DLL output matches unity/original-DSP processor");
        check(SUCCEEDED(apo->Reset()),"reset while connections stay locked");
        // Poisoned silent input must never be read; aliased connection metadata
        // must also preserve the incoming frame count and buffer flags.
        APO_CONNECTION_PROPERTY in{1,1024,BUFFER_SILENT,APO_CONNECTION_PROPERTY_SIGNATURE};
        APO_CONNECTION_PROPERTY out{reinterpret_cast<UINT_PTR>(output.data()),0,BUFFER_INVALID,APO_CONNECTION_PROPERTY_SIGNATURE};
        APO_CONNECTION_PROPERTY* ip[]={&in}; APO_CONNECTION_PROPERTY* op[]={&out};
        rt->APOProcess(1,ip,1,op);
        check(out.u32ValidFrameCount==1024 && out.u32BufferFlags==BUFFER_SILENT,"silent/null-read protection");
        in={reinterpret_cast<UINT_PTR>(input.data()),512,BUFFER_VALID,APO_CONNECTION_PROPERTY_SIGNATURE};
        rt->APOProcess(1,ip,1,ip);
        check(in.u32ValidFrameCount==512 && in.u32BufferFlags!=BUFFER_INVALID,"in-place metadata alias");
        in.u32ValidFrameCount=max_frames+1;
        rt->APOProcess(1,ip,1,op);
        check(out.u32ValidFrameCount==0 && out.u32BufferFlags==BUFFER_INVALID,"reject oversized host buffer");
        Status status{};
        check(SUCCEEDED(control->GetStatus(&status)) && status.locked && status.frames==4096+1024+512 && status.faults==1,"instance status");
        check(SUCCEEDED(control->SetSettings(Settings{2,4,true,500}.pack())),"publish runtime settings");
        check(SUCCEEDED(config->UnlockForProcess()),"unlock");
        check(SUCCEEDED(config->LockForProcess(1,ins,1,outs)),"relock fresh state");
        check(SUCCEEDED(config->UnlockForProcess()),"final unlock");
        check(SUCCEEDED(control->SetSettings(Settings{}.pack())),"restore default settings");
        effects->Release(); control->Release(); rt->Release(); config->Release(); apo->Release();
        check(unload()==S_OK,"all objects released");
        std::printf("PASS class=%s latency_100ns=%lld\n",unity?"unity":"original-dsp",static_cast<long long>(delay));
    }
    // Windows composite APOs aggregate their children. Verify controlling
    // IUnknown identity and reference accounting, not just null-outer creation.
    for(bool unity : {false,true}) {
        struct Outer final : IUnknown {
            ULONG refs=1; IUnknown* inner=nullptr;
            HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id,void** out) override {
                if(!out)return E_POINTER;*out=nullptr;
                if(id==IID_IUnknown){*out=static_cast<IUnknown*>(this);AddRef();return S_OK;}
                return inner ? inner->QueryInterface(id,out) : E_NOINTERFACE;
            }
            ULONG STDMETHODCALLTYPE AddRef() override {return ++refs;}
            ULONG STDMETHODCALLTYPE Release() override {return --refs;}
        } outer;
        IClassFactory* factory=nullptr;
        check(SUCCEEDED(get(unity?clsid_unity:clsid_dsp,IID_IClassFactory,reinterpret_cast<void**>(&factory))),"aggregate factory");
        void* invalid=nullptr;
        check(factory->CreateInstance(&outer,__uuidof(IAudioProcessingObject),&invalid)==E_NOINTERFACE && !invalid,"aggregate creation requires IUnknown");
        check(SUCCEEDED(factory->CreateInstance(&outer,IID_IUnknown,reinterpret_cast<void**>(&outer.inner))),"aggregate inner creation");
        factory->Release();
        IAudioProcessingObject* apo=nullptr;
        check(SUCCEEDED(outer.QueryInterface(__uuidof(IAudioProcessingObject),reinterpret_cast<void**>(&apo))),"aggregate public interface");
        IUnknown* identity=nullptr;
        check(SUCCEEDED(apo->QueryInterface(IID_IUnknown,reinterpret_cast<void**>(&identity))) && identity==static_cast<IUnknown*>(&outer),"aggregate controlling identity");
        check(outer.refs==3,"aggregate references delegated to outer");
        identity->Release();
        check(SUCCEEDED(apo->Initialize(0,nullptr)),"aggregate initialize");
        apo->Release();
        check(outer.refs==1 && unload()==S_FALSE,"outer retains inner lifetime");
        outer.inner->Release();outer.inner=nullptr;
        check(unload()==S_OK,"aggregate destruction releases module");
    }
    std::printf("PASS COM aggregation identity and lifetime (both classes)\n");
    // Exercise the initialization layout actually supplied by the engine,
    // including RAW bypass and discovery-only instances.
    for (bool discovery : {false,true}) {
        IClassFactory* factory=nullptr;
        check(SUCCEEDED(get(clsid_dsp,IID_IClassFactory,reinterpret_cast<void**>(&factory))),"engine-init factory");
        IAudioProcessingObject* apo=nullptr;
        check(SUCCEEDED(factory->CreateInstance(nullptr,__uuidof(IAudioProcessingObject),reinterpret_cast<void**>(&apo))),"engine-init object");
        factory->Release();
        APOInitSystemEffects2 init{};
        init.APOInit.cbSize=sizeof(init); init.APOInit.clsid=clsid_dsp;
        init.InitializeForDiscoveryOnly=discovery;
        if (!discovery) init.AudioProcessingMode={0x9e90ea20,0xb493,0x4fd1,{0xa1,0xa8,0x7e,0x13,0x61,0xa9,0x56,0xcf}};
        check(SUCCEEDED(apo->Initialize(sizeof(init),reinterpret_cast<BYTE*>(&init))),"engine SystemEffects2 initialization");
        HNSTIME delay=-1;
        check(SUCCEEDED(apo->GetLatency(&delay)) && delay==(discovery?213334:0),"RAW/discovery latency");
        IAudioProcessingObjectConfiguration* config=nullptr;
        check(SUCCEEDED(apo->QueryInterface(__uuidof(IAudioProcessingObjectConfiguration),reinterpret_cast<void**>(&config))),"engine-init config");
        Media media;
        float samples[32]{}; samples[0]=.125f;
        const auto original=samples[0];
        APO_CONNECTION_DESCRIPTOR descriptor{APO_CONNECTION_BUFFER_TYPE_EXTERNAL,
            reinterpret_cast<UINT_PTR>(samples),16,&media,APO_CONNECTION_DESCRIPTOR_SIGNATURE};
        APO_CONNECTION_DESCRIPTOR* descs[]={&descriptor};
        const auto hr=config->LockForProcess(1,descs,1,descs);
        if (discovery) check(hr==APOERR_NOT_INITIALIZED,"discovery instance cannot process");
        else {
            check(SUCCEEDED(hr),"RAW instance locks");
            IAudioProcessingObjectRT* rt=nullptr;
            check(SUCCEEDED(apo->QueryInterface(__uuidof(IAudioProcessingObjectRT),reinterpret_cast<void**>(&rt))),"RAW RT");
            APO_CONNECTION_PROPERTY connection{reinterpret_cast<UINT_PTR>(samples),16,BUFFER_VALID,APO_CONNECTION_PROPERTY_SIGNATURE};
            APO_CONNECTION_PROPERTY* conns[]={&connection};
            rt->APOProcess(1,conns,1,conns);
            check(samples[0]==original && connection.u32ValidFrameCount==16,"RAW stays zero-delay unity");
            rt->Release(); check(SUCCEEDED(config->UnlockForProcess()),"RAW unlock");
        }
        config->Release(); apo->Release();
        check(unload()==S_OK,"engine-init objects released");
        std::printf("PASS engine_init=%s\n",discovery?"discovery-only":"RAW");
    }
    FreeLibrary(dll); CoUninitialize();
    std::puts("Isolated DLL ABI test only; no endpoint association or audiodg measurement.");
}
