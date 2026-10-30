"""Verify Windows executables directly or through --wine on a Linux build host."""
import argparse,json,os,subprocess,tempfile,hashlib
from pathlib import Path
import numpy as np
import torch
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--binaries',type=Path,default=root/'build-win64');p.add_argument('--wine',type=Path);args=p.parse_args()
binaries=args.binaries.resolve();prefix=[str(args.wine)] if args.wine else []
def execute(name,*arguments,expected=0):
 result=subprocess.run(prefix+[str(binaries/name),*map(str,arguments)],cwd=binaries,capture_output=True,text=True)
 if result.returncode!=expected:raise RuntimeError(f'{name}: exit={result.returncode}\n{result.stdout}\n{result.stderr}')
 return result.stdout.strip()
report={'environment':'Wine compatibility execution on Linux; no Windows audio device' if args.wine else 'Windows process execution; no audio device installation','processor':execute('spectral_apo_processor_unit.exe'),'apo_abi':execute('spectral_apo_smoke.exe','SpectralAudio.dll')}
catalog=json.loads(execute('spectral_apo_runtime.exe','models'))
assert len(catalog)==25 and [s for s in catalog if s['available']]==[{'game':2,'level':4,'available':True}]
report['model_slots']=25;report['available_slots']=[{'game':2,'level':4}]
torch.set_num_threads(1);rng=np.random.default_rng(413)
f=rng.uniform(0,1e5,(1024,64)).astype('float32');f[:128]=0
with tempfile.TemporaryDirectory(prefix='spectral-probe-') as folder:
 folder=Path(folder);inp=folder/'input.bin';out=folder/'output.bin';f.tofile(inp)
 def winpath(path):return 'Z:'+str(path).replace('/','\\') if args.wine else str(path)
 execute('spectral_model_probe.exe',winpath(inp),winpath(out));native=np.fromfile(out,dtype='float32').reshape(-1,64)
model=torch.jit.load(str(root/'models/predictor.ts'),map_location='cpu').eval();norm=np.load(root/'models/predictor.norm.npz')
x=np.clip((f-norm['mean'])/norm['std'],-10,10)
with torch.inference_mode():reference,_=model(torch.from_numpy(x)[None],torch.zeros(1,1,128))
error=np.abs(native-reference[0].numpy());assert native.shape==f.shape and np.isfinite(native).all() and error.max()<2e-4
report['model_probe_frames']=len(f);report['log_gain_max_absolute_error']=float(error.max())
report['binaries']={n:hashlib.sha256((binaries/n).read_bytes()).hexdigest() for n in ['SpectralAudio.dll','spectral_apo_processor_unit.exe','spectral_apo_runtime.exe','spectral_apo_measure.exe','spectral_apo_smoke.exe']}
(root/'validation-windows.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
