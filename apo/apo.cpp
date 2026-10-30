#include "contract.hpp"
#include "processor.hpp"
#include "runtime.hpp"
#include <mmdeviceapi.h>
#include <ks.h>
#include <ksmedia.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <cwchar>
#include <new>

HMODULE spectral_apo_module = nullptr;

namespace {
using namespace spectralapo;
std::atomic<long> objects{0}, server_locks{0};
// SDK ksmedia.h GUID, kept local for older MinGW headers.
constexpr PROPERTYKEY endpoint_guid_key={{0x1da5d803,0xd492,0x4edd,{0x8c,0x23,0xe0,0xc0,0xff,0xee,0x7f,0x0e}},4};
constexpr GUID raw_mode = {0x9e90ea20,0xb493,0x4fd1,{0xa1,0xa8,0x7e,0x13,0x61,0xa9,0x56,0xcf}};
static_assert(std::atomic<UINT64>::is_always_lock_free, "Build APO for x64");

APO_REG_PROPERTIES registration(bool unity) {
    APO_REG_PROPERTIES p{};
    p.clsid = unity ? clsid_unity : clsid_dsp;
    p.Flags = static_cast<APO_FLAG>(APO_FLAG_DEFAULT | APO_FLAG_INPLACE);
    std::wcscpy(p.szFriendlyName, unity ? L"Spectral Audio Mount Probe" : L"Spectral Audio Enhancement");
    std::wcscpy(p.szCopyrightInfo, L"Spectral Audio");
    p.u32MajorVersion = 1;
    p.u32MinInputConnections = p.u32MaxInputConnections = 1;
    p.u32MinOutputConnections = p.u32MaxOutputConnections = 1;
    p.u32MaxInstances = UINT32_MAX;
    p.u32NumAPOInterfaces = 1;
    p.iidAPOInterfaceList[0] = __uuidof(IAudioProcessingObject);
    return p;
}

bool supported(IAudioMediaType* type) {
    if (!type) return false;
    UNCOMPRESSEDAUDIOFORMAT f{};
    if (FAILED(type->GetUncompressedAudioFormat(&f))) return false;
    return IsEqualGUID(f.guidFormatType, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) &&
        f.dwSamplesPerFrame == 2 && f.dwBytesPerSampleContainer == 4 &&
        f.dwValidBitsPerSample == 32 && f.fFramesPerSecond == 48000.f &&
        (f.dwChannelMask == 0 || f.dwChannelMask == (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT));
}

class Apo final : public IAudioProcessingObject, public IAudioProcessingObjectRT,
    public IAudioProcessingObjectConfiguration, public IAudioSystemEffects2, public Control {
    Runtime runtime_;
    std::atomic<ULONG> refs_{1};
    IUnknown* outer_ = nullptr;
    struct InnerUnknown final : IUnknown {
        Apo* owner;
        explicit InnerUnknown(Apo* p) : owner(p) {}
        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id,void** out) override {return owner->inner_query(id,out);}
        ULONG STDMETHODCALLTYPE AddRef() override {return owner->inner_addref();}
        ULONG STDMETHODCALLTYPE Release() override {return owner->inner_release();}
    } inner_{this};
    std::atomic<UINT32> settings_{Settings{}.pack()};
    std::atomic<UINT64> callbacks_{0}, frames_{0}, faults_{0};
    std::atomic<UINT64> max_ticks_{0};
    UINT64 frequency_ = 0;
    std::atomic<bool> locked_{false};
    bool initialized_ = false, unity_, raw_ = false, discovery_ = false;
    UINT32 max_input_ = 0, max_output_ = 0;
    std::unique_ptr<Processor> processor_;
public:
    explicit Apo(bool unity,IUnknown* outer=nullptr) : outer_(outer), unity_(unity) { ++objects; runtime_.attach(unity); if(runtime_.slot) GetModuleFileNameW(spectral_apo_module,runtime_.slot->module,512); }
    ~Apo() { if(runtime_.slot) runtime_.stage(7,runtime_.slot->result); runtime_.release(); --objects; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        return outer_ ? outer_->QueryInterface(id,out) : inner_query(id,out);
    }
    HRESULT inner_query(REFIID id, void** out) {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id == IID_IUnknown) {*out=&inner_;inner_addref();return S_OK;}
        if (id == __uuidof(IAudioProcessingObject))
            *out = static_cast<IAudioProcessingObject*>(this);
        else if (id == __uuidof(IAudioProcessingObjectRT)) *out = static_cast<IAudioProcessingObjectRT*>(this);
        else if (id == __uuidof(IAudioProcessingObjectConfiguration)) *out = static_cast<IAudioProcessingObjectConfiguration*>(this);
        else if (id == __uuidof(IAudioSystemEffects) || id == __uuidof(IAudioSystemEffects2))
            *out = static_cast<IAudioSystemEffects2*>(this);
        else if (id == iid_control) *out = static_cast<Control*>(this);
        else return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    ULONG inner_addref() {return ++refs_;}
    ULONG inner_release() {const auto n=--refs_;if(!n)delete this;return n;}
    ULONG STDMETHODCALLTYPE AddRef() override { return outer_ ? outer_->AddRef() : inner_addref(); }
    ULONG STDMETHODCALLTYPE Release() override {return outer_ ? outer_->Release() : inner_release();}
    HRESULT STDMETHODCALLTYPE Initialize(UINT32 bytes, BYTE* data) override {
        if(runtime_.slot) runtime_.slot->init_bytes=bytes;
        const auto hr=initialize(bytes,data);
        if(runtime_.slot) { runtime_.slot->raw=raw_; runtime_.slot->discovery=discovery_; }
        runtime_.stage(2,hr); return hr;
    }
    HRESULT initialize(UINT32 bytes, BYTE* data) {
        if (initialized_) return APOERR_ALREADY_INITIALIZED;
        if (bytes || data) {
            if (!data || bytes < sizeof(APOInitBaseStruct)) return E_INVALIDARG;
            const auto* base = reinterpret_cast<const APOInitBaseStruct*>(data);
            if (base->cbSize != bytes) return E_INVALIDARG;
            if (base->clsid != (unity_ ? clsid_unity : clsid_dsp)) return APOERR_INVALID_APO_CLSID;
            if (bytes != sizeof(APOInitSystemEffects) && bytes != sizeof(APOInitSystemEffects2)) return E_INVALIDARG;
            IPropertyStore* properties = nullptr;
            if (bytes == sizeof(APOInitSystemEffects2)) {
                const auto* init = reinterpret_cast<const APOInitSystemEffects2*>(data);
                raw_ = IsEqualGUID(init->AudioProcessingMode, raw_mode);
                discovery_ = init->InitializeForDiscoveryOnly != FALSE;
                properties = init->pAPOSystemEffectsProperties;
                if (runtime_.slot && init->pDeviceCollection) {
                    IMMDevice* device=nullptr;
                    if(SUCCEEDED(init->pDeviceCollection->Item(init->nSoftwareIoDeviceInCollection,&device))) {
                        LPWSTR id=nullptr;
                        if(SUCCEEDED(device->GetId(&id))) { wcsncpy_s(runtime_.slot->endpoint,id,_TRUNCATE); CoTaskMemFree(id); }
                        device->Release();
                    }
                }
            } else properties = reinterpret_cast<const APOInitSystemEffects*>(data)->pAPOSystemEffectsProperties;
            if (properties) {
                PROPVARIANT value{};
                const HRESULT hr = properties->GetValue(settings_key, &value);
                if (SUCCEEDED(hr) && value.vt == VT_UI4) {
                    const auto s = Settings::unpack(value.ulVal);
                    if (!s.valid() || !spectral_model_available(int(s.game),int(s.level))) { PropVariantClear(&value); return E_INVALIDARG; }
                    settings_.store(s.pack());
                }
                PropVariantClear(&value);
            }
        }
        if(runtime_.slot && data && bytes >= sizeof(APOInitSystemEffects)) {
            const auto* init=reinterpret_cast<const APOInitSystemEffects*>(data);
            if(init->pAPOEndpointProperties) {
                PROPVARIANT v{};
                if(SUCCEEDED(init->pAPOEndpointProperties->GetValue(endpoint_guid_key,&v))) {
                    if(v.vt==VT_LPWSTR && v.pwszVal && std::wcslen(v.pwszVal)==38) {
                        const std::wstring id=std::wstring(L"{0.0.0.00000000}.")+v.pwszVal;
                        wcsncpy_s(runtime_.slot->endpoint,id.c_str(),_TRUNCATE);
                    }
                }
                PropVariantClear(&v);
            }
        }
        LARGE_INTEGER frequency{};
        if (!QueryPerformanceFrequency(&frequency)) return E_FAIL;
        frequency_ = static_cast<UINT64>(frequency.QuadPart);
        initialized_ = true; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Reset() override {
        if (!initialized_) return APOERR_NOT_INITIALIZED;
        // Host serializes Reset with APOProcess, including while connections
        // remain locked. Reset neither allocates nor changes connections.
        return !processor_ || processor_->reset() ? S_OK : E_FAIL;
    }
    HRESULT STDMETHODCALLTYPE GetLatency(HNSTIME* latency) override {
        if (!latency) return E_POINTER;
        // Round up to 100 ns; never under-report the 1024-frame delay.
        *latency = unity_ || raw_ ? 0 : (Processor::latency_frames*10000000ULL+47999)/48000;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetRegistrationProperties(APO_REG_PROPERTIES** out) override {
        if (!out) return E_POINTER;
        *out = static_cast<APO_REG_PROPERTIES*>(CoTaskMemAlloc(sizeof(APO_REG_PROPERTIES)));
        if (!*out) return E_OUTOFMEMORY;
        **out = registration(unity_); return S_OK;
    }
    HRESULT format(IAudioMediaType* opposite, IAudioMediaType* requested, IAudioMediaType** out) {
        if (out) *out = nullptr;
        if (!requested) return E_POINTER;
        if (locked_) return APOERR_APO_LOCKED;
        if(runtime_.slot) {
            UNCOMPRESSEDAUDIOFORMAT f{};
            if(SUCCEEDED(requested->GetUncompressedAudioFormat(&f))) {runtime_.slot->rate=DWORD(f.fFramesPerSecond);runtime_.slot->channels=f.dwSamplesPerFrame;}
        }
        if (!supported(requested) || (opposite && !supported(opposite))) {runtime_.stage(3,APOERR_FORMAT_NOT_SUPPORTED); return APOERR_FORMAT_NOT_SUPPORTED;}
        if (out) { requested->AddRef(); *out = requested; }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE IsInputFormatSupported(IAudioMediaType* o, IAudioMediaType* r, IAudioMediaType** s) override { return format(o,r,s); }
    HRESULT STDMETHODCALLTYPE IsOutputFormatSupported(IAudioMediaType* o, IAudioMediaType* r, IAudioMediaType** s) override { return format(o,r,s); }
    HRESULT STDMETHODCALLTYPE GetInputChannelCount(UINT32* out) override {
        if (!out) return E_POINTER;
        if (!initialized_) return APOERR_NOT_INITIALIZED;
        *out = 2; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE LockForProcess(UINT32 ni, APO_CONNECTION_DESCRIPTOR** in,
        UINT32 no, APO_CONNECTION_DESCRIPTOR** out) override {
        const auto hr=lock(ni,in,no,out);
        if(runtime_.slot) {
            runtime_.slot->locked=SUCCEEDED(hr);
            if(SUCCEEDED(hr)) {UNCOMPRESSEDAUDIOFORMAT f{};if(SUCCEEDED(in[0]->pFormat->GetUncompressedAudioFormat(&f))){runtime_.slot->rate=DWORD(f.fFramesPerSecond);runtime_.slot->channels=f.dwSamplesPerFrame;}}
        }
        runtime_.stage(4,hr); return hr;
    }
    HRESULT lock(UINT32 ni, APO_CONNECTION_DESCRIPTOR** in, UINT32 no, APO_CONNECTION_DESCRIPTOR** out) {
        if (!initialized_ || discovery_) return APOERR_NOT_INITIALIZED;
        if (locked_) return APOERR_APO_LOCKED;
        if (ni != 1 || no != 1) return APOERR_NUM_CONNECTIONS_INVALID;
        if (!in || !out || !in[0] || !out[0]) return E_POINTER;
        if (in[0]->u32Signature != APO_CONNECTION_DESCRIPTOR_SIGNATURE ||
            out[0]->u32Signature != APO_CONNECTION_DESCRIPTOR_SIGNATURE ||
            !supported(in[0]->pFormat) || !supported(out[0]->pFormat)) return APOERR_INVALID_CONNECTION_FORMAT;
        if (!in[0]->u32MaxFrameCount || out[0]->u32MaxFrameCount < in[0]->u32MaxFrameCount)
            return APOERR_INVALID_OUTPUT_MAXFRAMECOUNT;
        try {
            if (!unity_ && !raw_) {
                processor_ = std::make_unique<Processor>(Settings::unpack(settings_.load()));

            }
        } catch (...) { return E_OUTOFMEMORY; }
        max_input_ = in[0]->u32MaxFrameCount; max_output_ = out[0]->u32MaxFrameCount;
        callbacks_ = 0; frames_ = 0; faults_ = 0; max_ticks_ = 0;
        locked_ = true; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE UnlockForProcess() override {
        if (!locked_) return APOERR_ALREADY_UNLOCKED;
        locked_ = false; processor_.reset(); if(runtime_.slot) runtime_.slot->locked=0; runtime_.stage(6,S_OK); return S_OK;
    }
    UINT32 STDMETHODCALLTYPE CalcInputFrames(UINT32 n) override { return n; }
    UINT32 STDMETHODCALLTYPE CalcOutputFrames(UINT32 n) override { return n; }
    void STDMETHODCALLTYPE APOProcess(UINT32 ni, APO_CONNECTION_PROPERTY** in,
        UINT32 no, APO_CONNECTION_PROPERTY** out) override {
        if (no != 1 || !out || !out[0]) return;
        auto& dst = *out[0];
        // Cache inputs before writing metadata: input/output structures can alias.
        const bool input_exists = ni == 1 && in && in[0];
        const UINT32 n = input_exists ? in[0]->u32ValidFrameCount : 0;
        const auto flag = input_exists ? in[0]->u32BufferFlags : BUFFER_INVALID;
        const auto source = input_exists ? in[0]->pBuffer : 0;
        dst.u32ValidFrameCount = 0; dst.u32BufferFlags = BUFFER_INVALID;
        if (!locked_ || !input_exists || n > max_input_ || n > max_output_ ||
            (flag != BUFFER_VALID && flag != BUFFER_SILENT) ||
            (n && (!dst.pBuffer || (flag == BUFFER_VALID && !source)))) {
            ++faults_; if(runtime_.slot) {runtime_.slot->faults=faults_.load(); runtime_.stage(5,E_INVALIDARG);} return;
        }
        LARGE_INTEGER started{}, ended{};
        QueryPerformanceCounter(&started);
        auto* output = reinterpret_cast<float*>(dst.pBuffer);
        const auto* input = reinterpret_cast<const float*>(source);
        bool silent = flag == BUFFER_SILENT;
        if (processor_) {
            const auto word=runtime_.settings(settings_.load(std::memory_order_acquire));
            const auto setting=Settings::unpack(word);
            if(setting.valid() && spectral_model_available(int(setting.game),int(setting.level))) settings_.store(word,std::memory_order_release);
            processor_->publish(Settings::unpack(settings_.load(std::memory_order_acquire)));
            if (!processor_->process(input, output, n, silent, silent)) ++faults_;
        } else if (n) {
            if (silent) std::fill_n(output, size_t(n)*2, 0.f);
            else std::memmove(output, input, size_t(n)*2*sizeof(float));
        }
        ++callbacks_; frames_ += n;
        dst.u32ValidFrameCount = n;
        dst.u32BufferFlags = silent ? BUFFER_SILENT : BUFFER_VALID;
        QueryPerformanceCounter(&ended);
        const auto ticks = static_cast<UINT64>(ended.QuadPart-started.QuadPart);
        // One audio writer per locked APO; no retry loop in the RT callback.
        if (ticks > max_ticks_.load(std::memory_order_relaxed)) max_ticks_.store(ticks,std::memory_order_relaxed);
        if(runtime_.slot) {
            runtime_.begin();
            auto& t=*runtime_.slot;
            t.stage=5; t.result=faults_.load() ? E_FAIL : S_OK;
            t.callbacks=callbacks_.load(); t.frames=frames_.load(); t.faults=faults_.load();
            t.max_ticks=max_ticks_.load(); t.frequency=frequency_; t.heartbeat=GetTickCount64();
            t.settings=processor_ ? processor_->applied_settings() : settings_.load();
            runtime_.end();
        }
    }
    HRESULT STDMETHODCALLTYPE GetEffectsList(GUID** ids, UINT* count, HANDLE) override {
        if (!ids || !count) return E_POINTER;
        *ids = nullptr; *count = 0;
        if (unity_ || raw_) return S_OK;
        *ids = static_cast<GUID*>(CoTaskMemAlloc(sizeof(GUID)));
        if (!*ids) return E_OUTOFMEMORY;
        **ids = clsid_dsp; *count = 1; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetSettings(UINT32 word) override {
        const auto s = Settings::unpack(word);
        if (!s.valid() || !spectral_model_available(int(s.game),int(s.level))) return E_INVALIDARG;
        settings_.store(s.pack(), std::memory_order_release);
        if(runtime_.data) InterlockedExchange(&runtime_.data->settings,LONG(s.pack()));
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetStatus(Status* s) override {
        if (!s) return E_POINTER;
        *s = {callbacks_.load(), frames_.load(), faults_.load(), max_ticks_.load(), frequency_, locked_.load(), unity_ || raw_};
        return S_OK;
    }
};

class Factory final : public IClassFactory {
    std::atomic<ULONG> refs_{1};
    bool unity_;
public:
    explicit Factory(bool u) : unity_(u) { ++objects; }
    ~Factory() { --objects; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id != IID_IUnknown && id != IID_IClassFactory) return E_NOINTERFACE;
        *out = static_cast<IClassFactory*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override { auto n = --refs_; if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        // Aggregated COM creation returns only the nondelegating IUnknown.
        // All public interfaces delegate identity and lifetime to the controller.
        if (outer && id != IID_IUnknown) return E_NOINTERFACE;
        auto* apo = new(std::nothrow) Apo(unity_,outer);
        if (!apo) return E_OUTOFMEMORY;
        const auto hr = apo->inner_query(id, out); apo->inner_release(); return hr;
    }
    HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) override {
        if (lock) ++server_locks; else --server_locks;
        return S_OK;
    }
};
} // namespace

extern "C" HRESULT WINAPI DllGetClassObject(REFCLSID clsid, REFIID iid, void** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (clsid != spectralapo::clsid_dsp && clsid != spectralapo::clsid_unity) return CLASS_E_CLASSNOTAVAILABLE;
    auto* f = new(std::nothrow) Factory(clsid == spectralapo::clsid_unity);
    if (!f) return E_OUTOFMEMORY;
    const auto hr = f->QueryInterface(iid, out); f->Release(); return hr;
}
extern "C" HRESULT WINAPI DllCanUnloadNow() { return objects == 0 && server_locks == 0 ? S_OK : S_FALSE; }
BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    // Static CRT builds retain thread notifications required by that runtime.
    if (reason == DLL_PROCESS_ATTACH) spectral_apo_module = module;
    return TRUE;
}
