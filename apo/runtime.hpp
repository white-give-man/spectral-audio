#pragma once
#include <windows.h>
#include "processor.hpp"
#include <string>
#include <cstring>
#include <cstddef>
#include <cstdio>

namespace spectralapo {
// File-backed, versioned IPC. Created by setup, never created by audiodg.
// Administrators publish settings; LocalService publishes per-instance evidence.
// No handles, pointers, waits or file operations in the audio callback.
constexpr DWORD runtime_magic = 0x53504132;
constexpr DWORD runtime_version = 3;
struct alignas(64) RuntimeSlot {
    volatile LONG64 sequence;
    DWORD pid, instance, unity, stage;
    HRESULT result;
    DWORD init_bytes, raw, discovery, settings, channels, rate, locked;
    UINT64 callbacks, frames, faults, max_ticks, frequency, heartbeat;
    wchar_t endpoint[160];
    wchar_t module[512];
    volatile LONG owner;
    DWORD eq_revision;
};
struct alignas(64) RuntimeData {
    DWORD magic, version, bytes;
    volatile LONG next_slot, settings;
    // Use the v2 reserved header: two banks, each holding ten signed 11-bit
    // gains and one enabled bit. Generation publishes the complete bank.
    volatile LONG eq_revision;
    volatile LONG eq_banks[2][5];
    RuntimeSlot slots[128];
    // v3 appends center frequencies to each bank. Zero means the factory center.
    volatile LONG eq_frequencies[2][Spectral_EQ_BANDS];
};
static_assert(offsetof(RuntimeData, slots) == 64 && sizeof(RuntimeSlot) == 1472);
constexpr size_t runtime_v2_bytes = offsetof(RuntimeData, eq_frequencies);
static_assert(runtime_v2_bytes == 64 + 128*1472);
static_assert(Spectral_EQ_BANDS == 10);
inline std::wstring runtime_path() {
    wchar_t root[32768]{};
    // Test override is process-local; the installer never sets this globally.
    if (!GetEnvironmentVariableW(L"SpectralAudio_TEST_RUNTIME", root, 32768)) {
        if (!GetEnvironmentVariableW(L"ProgramData", root, 32768)) return {};
        return std::wstring(root) + L"\\SpectralAudio\\runtime-v2.bin";
    }
    return root;
}
class Runtime {
    HANDLE file_ = INVALID_HANDLE_VALUE, map_ = nullptr;
public:
    RuntimeData* data = nullptr;
    RuntimeSlot* slot = nullptr;
    Runtime() = default;
    Runtime(const Runtime&) = delete;
    ~Runtime() { if (data) UnmapViewOfFile(data); if (map_) CloseHandle(map_); if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_); }
    DWORD open(bool write, bool create = false) {
        const auto path = runtime_path();
        file_ = CreateFileW(path.c_str(), GENERIC_READ | (write ? GENERIC_WRITE : 0),
            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, create ? CREATE_NEW : OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file_ == INVALID_HANDLE_VALUE) return GetLastError();
        if (create) {
            LARGE_INTEGER size{}; size.QuadPart = sizeof(RuntimeData);
            if (!SetFilePointerEx(file_,size,nullptr,FILE_BEGIN) || !SetEndOfFile(file_)) return GetLastError();
        }
        LARGE_INTEGER size{};
        if (!GetFileSizeEx(file_, &size)) return GetLastError();
        const bool legacy = size.QuadPart == runtime_v2_bytes && !write;
        if (size.QuadPart != sizeof(RuntimeData) && !legacy) return ERROR_BAD_LENGTH;
        map_ = CreateFileMappingW(file_,nullptr,write ? PAGE_READWRITE : PAGE_READONLY,0,0,nullptr);
        if (!map_) return GetLastError();
        data = static_cast<RuntimeData*>(MapViewOfFile(map_,write ? FILE_MAP_WRITE : FILE_MAP_READ,0,0,SIZE_T(size.QuadPart)));
        if (!data) return GetLastError();
        if (create) { std::memset(data,0,sizeof(*data)); data->version=runtime_version; data->bytes=sizeof(*data); data->settings=97538; MemoryBarrier(); data->magic=runtime_magic; }
        if (data->magic != runtime_magic || data->version != (legacy ? 2u : runtime_version) || data->bytes != size.QuadPart) {
            UnmapViewOfFile(data);
            data = nullptr;
            return ERROR_REVISION_MISMATCH;
        }
        return ERROR_SUCCESS;
    }
    void attach(bool unity) {
        wchar_t image[32768]{}, test[2]{};
        GetModuleFileNameW(nullptr,image,32768);
        const auto leaf=wcsrchr(image,L'\\');
        if (_wcsicmp(leaf ? leaf+1 : image,L"audiodg.exe") != 0 &&
            !GetEnvironmentVariableW(L"SpectralAudio_TEST_RUNTIME",test,2)) return;
        const auto error=open(true);
        if (error != ERROR_SUCCESS) {
            wchar_t root[32768]{};
            if(GetEnvironmentVariableW(L"ProgramData",root,32768)) {
                const auto path=std::wstring(root)+L"\\SpectralAudio\\diagnostics\\runtime-open-"+std::to_wstring(GetCurrentProcessId())+L".txt";
                HANDLE log=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
                if(log!=INVALID_HANDLE_VALUE) {char text[128];const int bytes=sprintf_s(text,"pid=%lu runtime_open_win32=%lu\r\n",GetCurrentProcessId(),error);DWORD written=0;WriteFile(log,text,DWORD(bytes),&written,nullptr);CloseHandle(log);}
            }
            return;
        }
        const DWORD serial=DWORD(InterlockedIncrement(&data->next_slot));
        for(DWORD i=0;i<128;++i) {
            auto* candidate=&data->slots[(serial+i)%128];
            if(InterlockedCompareExchange(&candidate->owner,LONG(GetCurrentProcessId()),0)==0) {slot=candidate;break;}
        }
        if(!slot) return;
        begin();
        std::memset(reinterpret_cast<BYTE*>(slot)+sizeof(LONG64),0,offsetof(RuntimeSlot,owner)-sizeof(LONG64));
        slot->eq_revision=0;
        slot->pid=GetCurrentProcessId(); slot->instance=serial; slot->unity=unity;
        end();
        stage(1,S_OK);
    }
    void release() noexcept { if(slot) InterlockedExchange(&slot->owner,0); }
    void begin() noexcept { if(slot) InterlockedIncrement64(&slot->sequence); }
    void end() noexcept { if(slot) InterlockedIncrement64(&slot->sequence); }
    void stage(DWORD stage_number, HRESULT hr) noexcept {
        if (!slot) return;
        begin(); slot->stage=stage_number; slot->result=hr; slot->heartbeat=GetTickCount64(); end();
    }
    bool read_equalizer(EqualizerSettings& eq, const uint32_t* known = nullptr) const noexcept {
        if (!data || data->magic != runtime_magic) return false;
        const auto revision = uint32_t(data->eq_revision);
        if (known && revision == *known) return false;
        MemoryBarrier();
        EqualizerSettings snapshot;
        snapshot.revision = revision;
        for (size_t i=0; i<5; ++i) {
            const auto word = uint32_t(data->eq_banks[revision & 1][i]);
            for (size_t j=0; j<2; ++j) {
                const auto bits = int((word >> (j*11)) & 2047u);
                snapshot.bands[i*2+j] = bits < 1024 ? bits : bits-2048;
            }
            if (i == 0) snapshot.enabled = (word & (1u << 22)) != 0;
        }
        if (data->version == runtime_version) {
            for (size_t i=0; i<Spectral_EQ_BANDS; ++i)
                snapshot.frequencies_hz[i] = data->eq_frequencies[revision & 1][i];
        }
        MemoryBarrier();
        if (revision != uint32_t(data->eq_revision)) return false;
        for (const int gain: snapshot.bands) if (gain < -600 || gain > 600) return false;
        for (const int hz: snapshot.frequencies_hz)
            if (hz && (hz < Spectral_EQ_MIN_HZ || hz > Spectral_EQ_MAX_HZ)) return false;
        eq = snapshot;
        return true;
    }
    // CLI only. Serialize writers using an OS-released byte lock beyond EOF;
    // a writer exiting mid-update leaves the previously published bank intact.
    DWORD write_equalizer(EqualizerSettings& eq, bool set_frequencies = true) noexcept {
        OVERLAPPED lock{};
        lock.Offset = sizeof(RuntimeData);
        if (!LockFileEx(file_, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &lock)) return GetLastError();
        const auto active_revision = uint32_t(data->eq_revision);
        eq.revision = active_revision + 1u;
        if (!set_frequencies) for (size_t i=0; i<Spectral_EQ_BANDS; ++i)
            eq.frequencies_hz[i] = data->eq_frequencies[active_revision & 1][i];
        for (size_t i=0; i<5; ++i) {
            auto word = (uint32_t(eq.bands[2*i]) & 2047u) |
                ((uint32_t(eq.bands[2*i+1]) & 2047u) << 11);
            if (i == 0 && eq.enabled) word |= 1u << 22;
            data->eq_banks[eq.revision & 1][i] = LONG(word);
        }
        for (size_t i=0; i<Spectral_EQ_BANDS; ++i)
            data->eq_frequencies[eq.revision & 1][i] = LONG(eq.frequencies_hz[i]);
        const auto* frequencies = reinterpret_cast<const BYTE*>(data) + offsetof(RuntimeData, eq_frequencies);
        DWORD error = ERROR_SUCCESS;
        if (FlushViewOfFile(frequencies, sizeof(data->eq_frequencies))) {
            InterlockedExchange(&data->eq_revision, LONG(eq.revision));
            if (!FlushViewOfFile(data, offsetof(RuntimeData, slots))) error = GetLastError();
        } else {
            error = GetLastError();
        }
        UnlockFileEx(file_, 0, 1, 0, &lock);
        return error;
    }
    UINT32 settings(UINT32 fallback) const noexcept {
        return data && data->magic==runtime_magic ? UINT32(data->settings) : fallback;
    }
};
}
