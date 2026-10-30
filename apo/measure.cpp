#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <fstream>
#include <iostream>
#include <vector>
#include <cmath>
#include <cstdint>
#include <algorithm>
#include <string>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>
#include <iomanip>
#include "processor.hpp"
void ck(HRESULT h){if(FAILED(h)){std::cerr<<"HRESULT "<<std::hex<<h<<std::endl;exit(2);}}
uint64_t qpc100(){LARGE_INTEGER q,f;QueryPerformanceCounter(&q);QueryPerformanceFrequency(&f);return uint64_t(double(q.QuadPart)*1e7/f.QuadPart);}
struct Packet{uint64_t qpc;uint32_t flags;std::vector<float> x;};
struct Mark{uint64_t frame,before,after;double queue_frames;};
// ASCII JSON keeps endpoint names lossless through Windows PowerShell 5.1 pipes.
void json_string(const wchar_t* s){
 std::cout<<'"';
 for(;*s;++s){unsigned c=static_cast<unsigned short>(*s);if(c=='"'||c=='\\')std::cout<<'\\'<<char(c);else if(c>=32&&c<127)std::cout<<char(c);else std::cout<<"\\u"<<std::hex<<std::setw(4)<<std::setfill('0')<<c<<std::dec;}
 std::cout<<'"';
}
int list_endpoints(){
 ck(CoInitializeEx(nullptr,COINIT_MULTITHREADED));
 IMMDeviceEnumerator* e=nullptr;ck(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,__uuidof(IMMDeviceEnumerator),(void**)&e));
 IMMDevice* def=nullptr;LPWSTR default_id=nullptr;if(SUCCEEDED(e->GetDefaultAudioEndpoint(eRender,eConsole,&def))){def->GetId(&default_id);def->Release();}
 IMMDeviceCollection* devices=nullptr;ck(e->EnumAudioEndpoints(eRender,DEVICE_STATE_ACTIVE,&devices));UINT count=0;ck(devices->GetCount(&count));
 std::cout<<'[';
 for(UINT i=0;i<count;++i){
  IMMDevice* d=nullptr;ck(devices->Item(i,&d));LPWSTR id=nullptr;ck(d->GetId(&id));IPropertyStore* properties=nullptr;PROPVARIANT name{},disabled{};
  if(SUCCEEDED(d->OpenPropertyStore(STGM_READ,&properties))){properties->GetValue(PKEY_Device_FriendlyName,&name);properties->GetValue(PKEY_AudioEndpoint_Disable_SysFx,&disabled);properties->Release();}
  IAudioClient* client=nullptr;WAVEFORMATEX* mix=nullptr;unsigned rate=0,channels=0;
  HRESULT hr=d->Activate(__uuidof(IAudioClient),CLSCTX_ALL,nullptr,(void**)&client);if(SUCCEEDED(hr)){hr=client->GetMixFormat(&mix);if(SUCCEEDED(hr)){rate=mix->nSamplesPerSec;channels=mix->nChannels;CoTaskMemFree(mix);}client->Release();}
  if(i)std::cout<<',';std::cout<<"{\"id\":";json_string(id);std::cout<<",\"name\":";json_string(name.vt==VT_LPWSTR?name.pwszVal:id);
  std::cout<<",\"is_default\":"<<((default_id&&wcscmp(default_id,id)==0)?"true":"false")<<",\"rate\":"<<rate<<",\"channels\":"<<channels<<",\"sysfx_disabled\":"<<((disabled.vt==VT_UI4&&disabled.ulVal!=0)?"true":"false")<<",\"format_hresult\":"<<static_cast<unsigned long>(hr)<<'}';
  PropVariantClear(&name);PropVariantClear(&disabled);CoTaskMemFree(id);d->Release();
 }
 std::cout<<"]\n";CoTaskMemFree(default_id);devices->Release();e->Release();CoUninitialize();return 0;
}
int main(int argc,char**argv){
 if(argc==2&&std::string(argv[1])=="--list")return list_endpoints();
 const std::string mode=argc>1?argv[1]:"Unity";
 if(mode!="Unity"&&mode!="DSP"&&mode!="Bypass"){std::cerr<<"mode must be Unity, DSP, or Bypass";return 2;}
 if(argc!=3){std::cerr<<"usage: spectral_apo_measure --list | Unity|DSP|Bypass endpoint-id";return 2;}
 const std::string endpoint_id=argv[2];
 if(endpoint_id.empty()||endpoint_id.size()>512||!std::all_of(endpoint_id.begin(),endpoint_id.end(),[](unsigned char c){return c>=32&&c<127;})){std::cerr<<"invalid endpoint id";return 2;}
 const std::wstring endpoint_wide(endpoint_id.begin(),endpoint_id.end());
 auto signal=[](uint64_t frame){double t=(frame%48000)/48000.;return frame>=48000&&frame<11*48000&&t<.08?float(.025*std::sin(2*3.141592653589793*(500*t+.5*7500/.08*t*t))*std::pow(std::sin(3.141592653589793*t/.08),2)):0.f;};
 std::vector<float> reference(12*48000*2);
 for(size_t i=0;i<reference.size()/2;i++)reference[2*i]=reference[2*i+1]=signal(i);
 if(mode=="DSP") {spectralapo::Processor processor;bool silent=false;for(size_t i=0;i<reference.size()/2;i+=480)processor.process(reference.data()+2*i,reference.data()+2*i,480,false,silent);}

 ck(CoInitializeEx(nullptr,COINIT_MULTITHREADED));IMMDeviceEnumerator*e;IMMDevice*d;IAudioClient *render,*capture;IAudioRenderClient*w;IAudioCaptureClient*r;
 ck(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,__uuidof(IMMDeviceEnumerator),(void**)&e));
 ck(e->GetDevice(endpoint_wide.c_str(),&d));
 IPropertyStore* properties=nullptr;
 if(SUCCEEDED(d->OpenPropertyStore(STGM_READ,&properties))){PROPVARIANT v{};auto hr=properties->GetValue(PKEY_AudioEndpoint_Disable_SysFx,&v);std::cout<<"DISABLE_SYSFX_HRESULT "<<std::hex<<hr<<std::dec<<" VT "<<v.vt<<" VALUE "<<v.ulVal<<std::endl;PropVariantClear(&v);properties->Release();}
 ck(d->Activate(__uuidof(IAudioClient),CLSCTX_ALL,nullptr,(void**)&render));ck(d->Activate(__uuidof(IAudioClient),CLSCTX_ALL,nullptr,(void**)&capture));
 WAVEFORMATEX fmt{};fmt.wFormatTag=WAVE_FORMAT_IEEE_FLOAT;fmt.nChannels=2;fmt.nSamplesPerSec=48000;fmt.wBitsPerSample=32;fmt.nBlockAlign=8;fmt.nAvgBytesPerSec=384000;
 ck(capture->Initialize(AUDCLNT_SHAREMODE_SHARED,AUDCLNT_STREAMFLAGS_LOOPBACK|0x80000000u|0x08000000u,1000000,0,&fmt,nullptr));ck(capture->GetService(__uuidof(IAudioCaptureClient),(void**)&r));
 ck(render->Initialize(AUDCLNT_SHAREMODE_SHARED,0x80000000u|0x08000000u,300000,0,&fmt,nullptr));ck(render->GetService(__uuidof(IAudioRenderClient),(void**)&w));
 IAudioEndpointVolume* volume=nullptr;float volume_before=-1,volume_after=-1;BOOL mute_before=FALSE,mute_after=FALSE;
 if(SUCCEEDED(d->Activate(__uuidof(IAudioEndpointVolume),CLSCTX_ALL,nullptr,(void**)&volume))){volume->GetMasterVolumeLevelScalar(&volume_before);volume->GetMute(&mute_before);}
 WAVEFORMATEX* mix=nullptr;if(SUCCEEDED(render->GetMixFormat(&mix))){std::cout<<"MIX_RATE "<<mix->nSamplesPerSec<<" CHANNELS "<<mix->nChannels<<std::endl;CoTaskMemFree(mix);}
 REFERENCE_TIME latency=0;ck(render->GetStreamLatency(&latency));std::cout<<"REPORTED_STREAM_LATENCY_100NS "<<latency<<std::endl;
#if defined(_MSC_VER)
 IAudioEffectsManager* effects=nullptr;HRESULT effect_hr=render->GetService(__uuidof(IAudioEffectsManager),(void**)&effects);
 std::cout<<"EFFECTS_SERVICE_HRESULT "<<std::hex<<effect_hr<<std::dec<<std::endl;
 if(SUCCEEDED(effect_hr)){AUDIO_EFFECT* list=nullptr;UINT32 count=0;effect_hr=effects->GetAudioEffects(&list,&count);std::cout<<"EFFECTS_LIST_HRESULT "<<std::hex<<effect_hr<<std::dec<<" count="<<count<<std::endl;if(SUCCEEDED(effect_hr))for(UINT32 i=0;i<count;i++){wchar_t id[40];StringFromGUID2(list[i].id,id,40);char narrow[40];for(int j=0;j<40;j++)narrow[j]=char(id[j]);std::cout<<"EFFECT "<<narrow<<" state="<<list[i].state<<std::endl;}CoTaskMemFree(list);effects->Release();}
#endif
 UINT32 size;ck(render->GetBufferSize(&size));std::vector<Packet> packets;packets.reserve(1500);std::vector<Mark> marks;uint64_t frame=0;
 auto fill=[&](UINT32 n){UINT32 queued=0;const auto query_before=qpc100();ck(render->GetCurrentPadding(&queued));const auto query_after=qpc100();const double query_mid=(double(query_before)+double(query_after))*.5;UINT32 marker_offset=0;BYTE*p;ck(w->GetBuffer(n,&p));uint64_t mark=0;for(UINT32 j=0;j<n;j++,frame++){if(frame>=48000&&frame<11*48000&&frame%48000==0){mark=frame;marker_offset=j;}float v=signal(frame);((float*)p)[2*j]=((float*)p)[2*j+1]=float(v);}uint64_t before=qpc100();ck(w->ReleaseBuffer(n,0));uint64_t after=qpc100();if(mark)marks.push_back({mark,before,after,std::max(0.,double(queued)-(double(before)-query_mid)*.0048)+marker_offset});};
 fill(size);ck(capture->Start());ck(render->Start());auto start=GetTickCount64();
 while(GetTickCount64()-start<12500){UINT32 n=0;ck(r->GetNextPacketSize(&n));int count=0;while(n&&count++<8){BYTE*p;DWORD flags;UINT64 pos,q;ck(r->GetBuffer(&p,&n,&flags,&pos,&q));Packet packet{q,flags,std::vector<float>(n)};for(UINT32 j=0;j<n;j++)packet.x[j]=(flags&AUDCLNT_BUFFERFLAGS_SILENT)?0:(((float*)p)[2*j]+((float*)p)[2*j+1])*.5f;packets.push_back(std::move(packet));ck(r->ReleaseBuffer(n));ck(r->GetNextPacketSize(&n));}UINT32 padding;ck(render->GetCurrentPadding(&padding));if(size>padding)fill(size-padding);Sleep(1);}
 if(volume){volume->GetMasterVolumeLevelScalar(&volume_after);volume->GetMute(&mute_after);volume->Release();}
 render->Stop();capture->Stop();std::ofstream f("direct-output.bin",std::ios::binary);for(auto&p:packets){uint32_t n=uint32_t(p.x.size());f.write((char*)&p.qpc,8);f.write((char*)&n,4);f.write((char*)&p.flags,4);f.write((char*)p.x.data(),n*4);}std::ofstream m("direct-marks.csv");m<<"frame,before_100ns,after_100ns,queue_frames\n";for(auto&v:marks)m<<v.frame<<","<<v.before<<","<<v.after<<","<<v.queue_frames<<"\n";

 if(packets.empty()||marks.size()<8){std::cerr<<"insufficient capture";return 3;}
 const auto q0=packets.front().qpc;
 size_t length=0;unsigned discontinuities=0,timestamp_errors=0;
 for(size_t i=0;i<packets.size();i++){const auto&p=packets[i];if(p.qpc<q0)continue;length=std::max(length,size_t(std::llround((p.qpc-q0)*.0048))+p.x.size());timestamp_errors+=(p.flags&4)!=0;if(i)discontinuities+=(p.flags&1)!=0;}
 if(length>48000*20){std::cerr<<"invalid capture timestamp span";return 3;}
 std::vector<float> y(length,0);for(const auto&p:packets){if(p.qpc<q0)continue;const auto at=size_t(std::llround((p.qpc-q0)*.0048));std::copy(p.x.begin(),p.x.end(),y.begin()+at);}
 double capture_energy=0;for(float sample:y)capture_energy+=double(sample)*sample;
 const double capture_rms=std::sqrt(capture_energy/double(y.size()));
 std::vector<double> delays,corrected,correlations,rms;
 std::ofstream results("measurement.json");results<<"{\"mode\":\""<<mode<<"\",\"capture_rms\":"<<capture_rms<<",\"boundary\":\"ReleaseBuffer to endpoint WASAPI loopback QPC; includes source queue; EFX coverage requires gain challenge\",\"chirps\":[";
 for(const auto&mark:marks){
   const size_t ref_at=size_t(mark.frame)+(mode=="DSP"?1024:0),count=3840;
   std::vector<float> t(count);for(size_t i=0;i<count;i++)t[i]=(reference[2*(ref_at+i)]+reference[2*(ref_at+i)+1])*.5f;
   const auto submit=int64_t(std::llround((int64_t(mark.before)-int64_t(q0))*.0048));
   const int64_t lo=std::max<int64_t>(0,submit-2400),hi=std::min<int64_t>(int64_t(length)-count,submit+19200);
   if(hi<=lo){std::cerr<<"missing correlation window";return 3;}
   auto score=[&](int64_t k,size_t step){double xy=0,xx=0,yy=0;for(size_t i=0;i<count;i+=step){double a=t[i],b=y[size_t(k)+i];xy+=a*b;xx+=a*a;yy+=b*b;}return std::abs(xy)/std::sqrt(xx*yy+1e-40);};
   int64_t best=lo;double best_score=-1;for(auto k=lo;k<=hi;k+=8){double v=score(k,8);if(v>best_score){best_score=v;best=k;}}
   const auto coarse=best;best_score=-1;for(auto k=std::max(lo,coarse-12);k<=std::min(hi,coarse+12);++k){double v=score(k,1);if(v>best_score){best_score=v;best=k;}}
   double energy=0;for(size_t i=0;i<count;i++)energy+=double(y[size_t(best)+i])*y[size_t(best)+i];
   const double delay=(double(int64_t(q0)-int64_t(mark.before)))/10000.+best/48.;
   if(!delays.empty())results<<',';results<<"{\"delay_ms\":"<<delay<<",\"queue_frames\":"<<mark.queue_frames<<",\"queue_corrected_ms\":"<<(delay-mark.queue_frames/48.)<<",\"correlation\":"<<best_score<<",\"rms\":"<<std::sqrt(energy/count)<<'}';
   delays.push_back(delay);corrected.push_back(delay-mark.queue_frames/48.);correlations.push_back(best_score);rms.push_back(std::sqrt(energy/count));
 }
 auto median=[](std::vector<double> a){std::sort(a.begin(),a.end());return(a[(a.size()-1)/2]+a[a.size()/2])*.5;};
 results<<"],\"median_ms\":"<<median(delays)<<",\"median_queue_corrected_ms\":"<<median(corrected)<<",\"queue_corrected_min_ms\":"<<*std::min_element(corrected.begin(),corrected.end())<<",\"queue_corrected_max_ms\":"<<*std::max_element(corrected.begin(),corrected.end())<<",\"render_buffer_frames\":"<<size<<",\"min_correlation\":"<<*std::min_element(correlations.begin(),correlations.end())<<",\"median_rms\":"<<median(rms)<<",\"timestamp_errors\":"<<timestamp_errors<<",\"discontinuities\":"<<discontinuities<<",\"volume_before\":"<<volume_before<<",\"volume_after\":"<<volume_after<<",\"mute_before\":"<<mute_before<<",\"mute_after\":"<<mute_after<<"}\n";
 std::cout<<"DONE target="<<endpoint_id<<" 48kHz render_buffer="<<size<<" chirps="<<marks.size()<<" packets="<<packets.size()<<std::endl;
}
