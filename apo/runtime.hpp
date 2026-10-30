#pragma once
#include <windows.h>
#include <string>
#include <cstring>
#include <cstddef>
#include <cstdio>

namespace spectralapo {
// File-backed, versioned IPC. Created by setup, never created by audiodg.
// Administrators publish settings; LocalService publishes per-instance evidence.
// No handles, pointers, waits or file operations in the audio callback.
constexpr DWORD runtime_magic = 0x53504132;
struct alignas(64) RuntimeSlot {
    volatile LONG64 sequence;
    DWORD pid, instance, unity, stage;
    HRESULT result;
    DWORD init_bytes, raw, discovery, settings, channels, rate, locked;
    UINT64 callbacks, frames, faults, max_ticks, frequency, heartbeat;
    wchar_t endpoint[160];
    wchar_t module[512];
    volatile LONG owner;
};
struct alignas(64) RuntimeData {
    DWORD magic, version, bytes;
    volatile LONG next_slot, settings;
    DWORD reserved[11];
    RuntimeSlot slots[128];
};
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
        if (!GetFileSizeEx(file_, &size) || size.QuadPart != sizeof(RuntimeData)) return ERROR_BAD_LENGTH;
        map_ = CreateFileMappingW(file_,nullptr,write ? PAGE_READWRITE : PAGE_READONLY,0,0,nullptr);
        if (!map_) return GetLastError();
        data = static_cast<RuntimeData*>(MapViewOfFile(map_,write ? FILE_MAP_WRITE : FILE_MAP_READ,0,0,sizeof(RuntimeData)));
        if (!data) return GetLastError();
        if (create) { std::memset(data,0,sizeof(*data)); data->version=2; data->bytes=sizeof(*data); data->settings=97538; MemoryBarrier(); data->magic=runtime_magic; }
        if (data->magic != runtime_magic || data->version != 2 || data->bytes != sizeof(*data)) return ERROR_REVISION_MISMATCH;
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
    UINT32 settings(UINT32 fallback) const noexcept {
        return data && data->magic==runtime_magic ? UINT32(data->settings) : fallback;
    }
};
}
