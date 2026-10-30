"""Export the supplied TorchScript model and paired normalization as plain C++ arrays."""
from pathlib import Path
import hashlib,json
import numpy as np
import torch
root=Path(__file__).resolve().parents[1]
from prepare_models import prepare
container_report=prepare(root/'models',root/'models')
(root/'validation-model-containers.json').write_text(json.dumps(container_report,indent=2)+'\n')
model=torch.jit.load(str(root/'models/predictor.ts'),map_location='cpu').eval()
checkpoint=torch.load(root/'models/predictor.pt',map_location='cpu',weights_only=False)
state=model.state_dict()
assert set(state)==set(checkpoint['state_dict'])
for key,value in state.items():
    assert torch.equal(value,checkpoint['state_dict'][key]), key
norm=np.load(root/'models/predictor.norm.npz')
for key in ['mean','std']:
    assert np.array_equal(norm[key],checkpoint[key])
assert norm['mean'].shape==(64,) and norm['std'].shape==(64,)
assert np.isfinite(norm['mean']).all() and (norm['std']>0).all()
bank=np.load(root/'models/filterbanks.npz')
arrays={k.replace('.','_'):v.numpy() for k,v in state.items()}
arrays.update(mean=norm['mean'],std=norm['std'],analysis=bank['analysis'],synthesis=bank['synthesis'])
header=['#pragma once','#include "model_registry.hpp"','namespace spectral::weights {']
source=['#include "model_data.hpp"','namespace spectral::weights {']
for key,value in arrays.items():
    value=np.asarray(value); assert np.isfinite(value).all()
    ctype='double' if key in ['analysis','synthesis'] else 'float'
    header.append(f'extern const {ctype} {key}[{value.size}];')
    vals=[format(float(x),'.17e' if ctype=='double' else '.9e')+('f' if ctype=='float' else '') for x in value.flat]
    source.append(f'const {ctype} {key}[{value.size}] = {{\n'+',\n'.join(','.join(vals[i:i+8]) for i in range(0,len(vals),8))+'\n};')
header.append('extern const ModelData predictor;');source.append('const ModelData predictor = {gru_weight_ih_l0,gru_weight_hh_l0,gru_bias_ih_l0,gru_bias_hh_l0,head_weight,head_bias,mean,std};');header.append('}');source.append('}')
(root/'generated/model_data.hpp').write_text('\n'.join(header)+'\n')
(root/'generated/model_data.cpp').write_text('\n'.join(source)+'\n')
report={'format':'plaintext C++ floating point arrays; no encryption','runtime':'native C++ GRU equivalent to supplied TorchScript','torchscript_checkpoint_exact_match':True,'normalization_checkpoint_exact_match':True,'files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((root/'models').iterdir())}}
(root/'model-manifest.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
