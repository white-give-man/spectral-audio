#include "contract.hpp"
#include <string>
#include <cwchar>

extern HMODULE spectral_apo_module;
namespace {
std::wstring guid_text(REFGUID id) {
    wchar_t guid[40]{}; StringFromGUID2(id,guid,40); return guid;
}
std::wstring key_for(REFCLSID id) {
    return std::wstring(L"SOFTWARE\\Classes\\CLSID\\")+guid_text(id);
}
std::wstring apo_key(REFCLSID id) {
    return std::wstring(L"SOFTWARE\\Classes\\AudioEngine\\AudioProcessingObjects\\")+guid_text(id);
}
HRESULT require_absent(const std::wstring& path) {
    HKEY key=nullptr;
    const auto result=RegOpenKeyExW(HKEY_LOCAL_MACHINE,path.c_str(),0,KEY_READ,&key);
    if (result==ERROR_SUCCESS) { RegCloseKey(key); return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS); }
    return result==ERROR_FILE_NOT_FOUND ? S_OK : HRESULT_FROM_WIN32(result);
}
HRESULT reserve_key(const std::wstring& path, bool& created) {
    HKEY key=nullptr; DWORD disposition=0;
    const auto result=RegCreateKeyExW(HKEY_LOCAL_MACHINE,path.c_str(),0,nullptr,0,
        KEY_SET_VALUE,nullptr,&key,&disposition);
    if (result!=ERROR_SUCCESS) return HRESULT_FROM_WIN32(result);
    RegCloseKey(key); created=disposition==REG_CREATED_NEW_KEY;
    return created ? S_OK : HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
}
HRESULT write_properties(const APO_REG_PROPERTIES& p) {
    HKEY key=nullptr;
    auto result=RegOpenKeyExW(HKEY_LOCAL_MACHINE,apo_key(p.clsid).c_str(),0,KEY_SET_VALUE,&key);
    if (result!=ERROR_SUCCESS) return HRESULT_FROM_WIN32(result);
    auto string_value=[&](const wchar_t* name,const wchar_t* value) {
        if (result==ERROR_SUCCESS) result=RegSetValueExW(key,name,0,REG_SZ,
            reinterpret_cast<const BYTE*>(value),DWORD((std::wcslen(value)+1)*sizeof(wchar_t)));
    };
    auto dword_value=[&](const wchar_t* name,DWORD value) {
        if (result==ERROR_SUCCESS) result=RegSetValueExW(key,name,0,REG_DWORD,
            reinterpret_cast<const BYTE*>(&value),sizeof(value));
    };
    // Same APO metadata names and types as Microsoft's SysVAD APO INF.
    // RegisterAPO/UnregisterAPO are not AudioEng.dll exports on Windows 11.
    string_value(L"FriendlyName",p.szFriendlyName); string_value(L"Copyright",p.szCopyrightInfo);
    dword_value(L"MajorVersion",p.u32MajorVersion); dword_value(L"MinorVersion",p.u32MinorVersion);
    dword_value(L"Flags",static_cast<DWORD>(p.Flags));
    dword_value(L"MinInputConnections",p.u32MinInputConnections);
    dword_value(L"MaxInputConnections",p.u32MaxInputConnections);
    dword_value(L"MinOutputConnections",p.u32MinOutputConnections);
    dword_value(L"MaxOutputConnections",p.u32MaxOutputConnections);
    dword_value(L"MaxInstances",p.u32MaxInstances); dword_value(L"NumAPOInterfaces",p.u32NumAPOInterfaces);
    for (UINT32 i=0;i<p.u32NumAPOInterfaces;++i)
        string_value((L"APOInterface"+std::to_wstring(i)).c_str(),guid_text(p.iidAPOInterfaceList[i]).c_str());
    RegCloseKey(key); return HRESULT_FROM_WIN32(result);
}
HRESULT current_path(std::wstring& path) {
    wchar_t buffer[32768]{};
    const auto n=GetModuleFileNameW(spectral_apo_module,buffer,32768);
    if (!n || n>=32768) return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    path.assign(buffer,n); return S_OK;
}
HRESULT existing_path(REFCLSID id, std::wstring& path) {
    wchar_t buffer[32768]{}; DWORD bytes=sizeof(buffer);
    const auto result=RegGetValueW(HKEY_LOCAL_MACHINE,(key_for(id)+L"\\InprocServer32").c_str(),
        nullptr,RRF_RT_REG_SZ,nullptr,buffer,&bytes);
    if (result!=ERROR_SUCCESS) return HRESULT_FROM_WIN32(result);
    path=buffer; return S_OK;
}
HRESULT write_com(REFCLSID id, const std::wstring& path) {
    HKEY key=nullptr;
    auto result=RegCreateKeyExW(HKEY_LOCAL_MACHINE,(key_for(id)+L"\\InprocServer32").c_str(),
        0,nullptr,0,KEY_SET_VALUE,nullptr,&key,nullptr);
    if (result!=ERROR_SUCCESS) return HRESULT_FROM_WIN32(result);
    result=RegSetValueExW(key,nullptr,0,REG_SZ,reinterpret_cast<const BYTE*>(path.c_str()),
        DWORD((path.size()+1)*sizeof(wchar_t)));
    if (result==ERROR_SUCCESS) {
        const wchar_t threading[]=L"Both";
        result=RegSetValueExW(key,L"ThreadingModel",0,REG_SZ,reinterpret_cast<const BYTE*>(threading),sizeof(threading));
    }
    RegCloseKey(key); return HRESULT_FROM_WIN32(result);
}
// Ask the object for the exact registration advertised to its engine host.
HRESULT properties(REFCLSID id, APO_REG_PROPERTIES** props) {
    using GetFactory=HRESULT (WINAPI*)(REFCLSID,REFIID,void**);
    const auto get=reinterpret_cast<GetFactory>(GetProcAddress(spectral_apo_module,"DllGetClassObject"));
    if (!get) return E_UNEXPECTED;
    IClassFactory* factory=nullptr;
    auto hr=get(id,IID_IClassFactory,reinterpret_cast<void**>(&factory));
    if (FAILED(hr)) return hr;
    IAudioProcessingObject* object=nullptr;
    hr=factory->CreateInstance(nullptr,__uuidof(IAudioProcessingObject),reinterpret_cast<void**>(&object));
    factory->Release();
    if (FAILED(hr)) return hr;
    hr=object->GetRegistrationProperties(props); object->Release(); return hr;
}
}

// Developer COM/APO registration only. This never associates a render endpoint.
extern "C" HRESULT WINAPI DllRegisterServer() {
    std::wstring path;
    auto hr=current_path(path); if (FAILED(hr)) return hr;
    const GUID ids[]={spectralapo::clsid_unity,spectralapo::clsid_dsp};
    // Never replace an existing COM class or APO metadata, including an earlier build.
    for (const auto& id:ids) {
        hr=require_absent(key_for(id)); if (FAILED(hr)) return hr;
        hr=require_absent(apo_key(id)); if (FAILED(hr)) return hr;
    }
    bool com_created[2]={false,false}, apo_created[2]={false,false};
    for (size_t i=0;i<2;++i) {
        hr=reserve_key(key_for(ids[i]),com_created[i]);
        if (SUCCEEDED(hr)) hr=reserve_key(apo_key(ids[i]),apo_created[i]);
        if (SUCCEEDED(hr)) hr=write_com(ids[i],path);
        if (SUCCEEDED(hr)) {
            APO_REG_PROPERTIES* p=nullptr;
            hr=properties(ids[i],&p);
            if (SUCCEEDED(hr)) { hr=write_properties(*p); CoTaskMemFree(p); }
        }
        if (FAILED(hr)) break;
    }
    if (FAILED(hr)) for (size_t i=0;i<2;++i) {
        if (apo_created[i]) RegDeleteTreeW(HKEY_LOCAL_MACHINE,apo_key(ids[i]).c_str());
        if (com_created[i]) RegDeleteTreeW(HKEY_LOCAL_MACHINE,key_for(ids[i]).c_str());
    }
    return hr;
}

extern "C" HRESULT WINAPI DllUnregisterServer() {
    std::wstring path;
    auto hr=current_path(path); if (FAILED(hr)) return hr;
    const GUID ids[]={spectralapo::clsid_unity,spectralapo::clsid_dsp};
    bool exists[2]={false,false};
    for (size_t i=0;i<2;++i) {
        std::wstring installed;
        hr=existing_path(ids[i],installed);
        if (hr==HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) continue;
        if (FAILED(hr)) return hr;
        if (_wcsicmp(installed.c_str(),path.c_str())!=0) return E_ACCESSDENIED;
        exists[i]=true;
    }
    HRESULT result=S_OK;
    for (size_t i=0;i<2;++i) if (exists[i]) {
        const auto a=RegDeleteTreeW(HKEY_LOCAL_MACHINE,apo_key(ids[i]).c_str());
        if (a!=ERROR_SUCCESS && a!=ERROR_FILE_NOT_FOUND) { result=HRESULT_FROM_WIN32(a); continue; }
        const auto r=RegDeleteTreeW(HKEY_LOCAL_MACHINE,key_for(ids[i]).c_str());
        if (r!=ERROR_SUCCESS && r!=ERROR_FILE_NOT_FOUND) result=HRESULT_FROM_WIN32(r);
    }
    return result;
}
