"""Normalize model containers using the Spectral Audio release schema.

Tensor values stay exact. Checkpoints retain weights, normalization and network
size only. TorchScript is exported from the project's predictor module; optional
debug records and tracing examples are omitted from the release container.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

import numpy as np
import torch


def prepare(source, destination):
    checkpoint = torch.load(source / 'predictor.pt', map_location='cpu', weights_only=False)
    with np.load(source / 'predictor.norm.npz', allow_pickle=False) as values:
        norm = {key: values[key].copy() for key in ('mean', 'std')}
    with np.load(source / 'filterbanks.npz', allow_pickle=False) as values:
        banks = {key: values[key].copy() for key in ('analysis', 'synthesis')}
    clean = {
        'state_dict': {key: value.detach().cpu().clone() for key, value in checkpoint['state_dict'].items()},
        'mean': np.array(norm['mean'], dtype=np.float32, copy=True),
        'std': np.array(norm['std'], dtype=np.float32, copy=True),
        'hidden': 128,
    }
    for key in ('mean', 'std'):
        if not np.array_equal(clean[key], checkpoint[key]):
            raise ValueError('Checkpoint normalization does not match the paired normalization file')
    if set(clean['state_dict']) != {'gru.weight_ih_l0', 'gru.weight_hh_l0', 'gru.bias_ih_l0', 'gru.bias_hh_l0', 'head.weight', 'head.bias'}:
        raise ValueError('Unexpected predictor parameter schema')
    # Use a neutral staging path so exporter stack traces cannot capture the
    # caller's checkout directory. No source checkpoint is modified in place.
    with tempfile.TemporaryDirectory(prefix='spectral-model-export-') as temporary:
        stage = Path(temporary)
        torch.save(clean, stage / 'predictor.pt')
        np.savez_compressed(stage / 'predictor.norm.npz', mean=clean['mean'], std=clean['std'])
        np.savez_compressed(stage / 'filterbanks.npz', analysis=banks['analysis'], synthesis=banks['synthesis'])
        shutil.copyfile(Path(__file__).with_name('spectral_predictor.py'), stage / 'spectral_predictor.py')
        worker = stage / 'export.py'
        worker.write_text('''import torch
from spectral_predictor import GainPredictor
torch.set_num_threads(1)
checkpoint=torch.load('predictor.pt',map_location='cpu',weights_only=False)
model=GainPredictor(checkpoint['hidden']).eval()
model.load_state_dict(checkpoint['state_dict'],strict=True)
with torch.inference_mode():
    traced=torch.jit.trace(model,(torch.zeros(1,1,64),torch.zeros(1,1,128)))
traced.save('predictor.ts')
''')
        subprocess.run([sys.executable, str(worker)], cwd=stage, check=True, capture_output=True, text=True)
        packed = stage / 'predictor.release.ts'
        with zipfile.ZipFile(stage / 'predictor.ts') as source_zip, zipfile.ZipFile(packed, 'w', zipfile.ZIP_STORED) as target_zip:
            for member in source_zip.infolist():
                if member.filename.endswith('.debug_pkl') or '/traced_inputs/' in member.filename or member.filename.endswith('/traced_inputs.pkl'):
                    continue
                info = zipfile.ZipInfo(member.filename, date_time=(1980, 1, 1, 0, 0, 0))
                target_zip.writestr(info, source_zip.read(member.filename))
        exported = torch.jit.load(str(packed), map_location='cpu').eval()
        reference = torch.jit.load(str(source / 'predictor.ts'), map_location='cpu').eval()
        if set(exported.state_dict()) != set(clean['state_dict']):
            raise ValueError('Exported parameter keys changed')
        for key, value in exported.state_dict().items():
            if not torch.equal(value, clean['state_dict'][key]):
                raise ValueError('Parameter changed during export: ' + key)
        generator = torch.Generator().manual_seed(20261028)
        max_error = 0.0
        with torch.inference_mode():
            for batch, frames in ((1, 1), (2, 17), (1, 256), (1, 1024)):
                features = torch.randn(batch, frames, 64, generator=generator)
                state = torch.randn(1, batch, 128, generator=generator)
                before, before_state = reference(features, state)
                after, after_state = exported(features, state)
                error = max(float((before - after).abs().max()), float((before_state - after_state).abs().max()))
                max_error = max(max_error, error)
                if not torch.equal(before, after) or not torch.equal(before_state, after_state):
                    raise ValueError('Export changed predictor outputs or recurrent states')
        destination.mkdir(parents=True, exist_ok=True)
        for name in ('predictor.pt', 'predictor.norm.npz', 'filterbanks.npz'):
            pending = destination / (name + '.pending')
            shutil.copyfile(stage / name, pending)
            os.replace(pending, destination / name)
        pending = destination / 'predictor.ts.pending'
        shutil.copyfile(packed, pending)
        os.replace(pending, destination / 'predictor.ts')
    return {'tensor_values_exact': True, 'torchscript_outputs_and_states_exact': True, 'max_absolute_error': max_error, 'checkpoint_keys': sorted(clean), 'debug_records_included': False, 'files': {name: hashlib.sha256((destination / name).read_bytes()).hexdigest() for name in ('predictor.ts', 'predictor.pt', 'predictor.norm.npz', 'filterbanks.npz')}}


if __name__ == '__main__':
    import json
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, default=root / 'models')
    parser.add_argument('--output', type=Path, default=root / 'models')
    args = parser.parse_args()
    torch.set_num_threads(1)
    result = prepare(args.input, args.output)
    (root / 'validation-model-containers.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
