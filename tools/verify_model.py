"""Compare native streaming frontend/GRU/OLA with the supplied TorchScript model."""
import argparse,ctypes as C,json,time,wave
from pathlib import Path
import numpy as np
import torch
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--library',type=Path,default=root/'build-linux/libspectral_verify.so');p.add_argument('--wav',type=Path);args=p.parse_args()
torch.set_num_threads(1)
lib=C.CDLL(str(args.library));ptr=C.c_void_p
lib.spectral_predict.argtypes=[ptr,ptr,C.c_int];lib.spectral_predict.restype=None
lib.spectral_render.argtypes=[ptr,ptr,C.c_int,C.c_int];lib.spectral_render.restype=C.c_int
lib.spectral_render_strength.argtypes=[ptr,ptr,C.c_int,C.c_int,C.c_float];lib.spectral_render_strength.restype=C.c_int
model=torch.jit.load(str(root/'models/predictor.ts'),map_location='cpu').eval()
norm=np.load(root/'models/predictor.norm.npz');banks=np.load(root/'models/filterbanks.npz')
rng=np.random.default_rng(20261028)
# Adversarial normalized feature ranges, including prolonged silent frames.
f=np.concatenate([np.zeros((128,64)),rng.uniform(0,2e5,(512,64)),np.maximum(0,norm['mean']+rng.normal(size=(512,64))*norm['std'])]).astype('float32')
y=np.empty_like(f);lib.spectral_predict(f.ctypes.data,y.ctypes.data,len(f))
x=np.clip((f-norm['mean'])/norm['std'],-10,10)
with torch.inference_mode(): ref,_=model(torch.from_numpy(x)[None],torch.zeros(1,1,128))
err=np.abs(y-ref[0].numpy());assert np.isfinite(y).all() and err.max()<2e-4,err.max()
report={'feature_frames':len(f),'log_gain_max_absolute_error':float(err.max()),'log_gain_mean_absolute_error':float(err.mean()),'pcm_cases':[]}
count=512*160;t=np.arange(count)/48000
pcm=np.stack([.03*np.sin(2*np.pi*440*t),.02*np.sin(2*np.pi*1800*t)],1).astype('float32')
pcm+=rng.normal(0,.005,pcm.shape).astype('float32');pcm[512*35:512*55]=0
cases=[('tones_noise_and_silence',pcm)]
if args.wav:
 with wave.open(str(args.wav),'rb') as w:
  assert (w.getframerate(),w.getnchannels(),w.getsampwidth())==(48000,2,2)
  audio=np.frombuffer(w.readframes(48000*12),dtype='<i2').reshape(-1,2).astype('float32')/32768
  cases.append(('recording',audio[:len(audio)//512*512]))
def render_reference(audio, strength=1.):
 result=[];window=np.hanning(1024)
 for ch in range(2):
  padded=np.pad(audio[:,ch].astype('float64')*32768,(512,512))
  frames=np.lib.stride_tricks.sliding_window_view(padded,1024)[::512]
  spec=np.fft.rfft(frames*window,axis=-1)
  features=(np.abs(spec)@banks['analysis'].T).astype('float32')
  features=np.clip((features-norm['mean'])/norm['std'],-10,10)
  with torch.inference_mode(): logs,_=model(torch.from_numpy(features)[None],torch.zeros(1,1,128))
  values=logs[0].numpy().astype('float64')
  gains=np.exp(np.where(values>0,values*strength,values))@banks['synthesis'].T
  rec=np.fft.irfft(spec*gains,n=1024,axis=-1)
  out=np.zeros(len(padded));div=np.zeros(len(padded))
  for i,frame in enumerate(rec):out[i*512:i*512+1024]+=frame*window;div[i*512:i*512+1024]+=window**2
  result.append(out[512:512+len(audio)]/div[512:512+len(audio)]/32768)
 return np.stack(result,1)
for label,audio in cases:
 # A final zero hop drains the streaming overlap, retaining the original duration.
 padded=np.ascontiguousarray(np.concatenate([audio,np.zeros((512,2),dtype='float32')]))
 output=np.empty_like(padded);start=time.perf_counter()
 assert lib.spectral_render(padded.ctypes.data,output.ctypes.data,len(padded)//512,0)==0
 seconds=time.perf_counter()-start
 reference=render_reference(audio);error=np.abs(output[512:]-reference)
 assert np.isfinite(output).all() and error.max()<3e-5,(label,error.max())
 # Stereo independence: a left-only signal must produce zero on the right.
 left=padded.copy();left[:,1]=0;one=np.empty_like(left)
 assert lib.spectral_render(left.ctypes.data,one.ctypes.data,len(left)//512,0)==0
 assert np.max(np.abs(one[:,1]))==0
 report['pcm_cases'].append({'case':label,'samples_per_channel':len(audio),'max_absolute_error':float(error.max()),'rms_error':float(np.sqrt(np.mean(error**2))),'native_seconds':seconds,'audio_seconds':len(audio)/48000,'realtime_factor':seconds/(len(audio)/48000),'stereo_independence':True})
report['strength_cases']=[]
for amount in (0.,.6,.735,1.):
 value=float(np.float32(amount))
 assert lib.spectral_render_strength(padded.ctypes.data,output.ctypes.data,len(padded)//512,0,value)==0
 expected=render_reference(audio,value);error=np.abs(output[512:]-expected)
 assert np.isfinite(output).all() and error.max()<3e-5,(amount,error.max())
 report['strength_cases'].append({'strength':amount,'max_absolute_error':float(error.max()),'rms_error':float(np.sqrt(np.mean(error**2)))})
(root/'validation-model.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
