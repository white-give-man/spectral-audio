"""Build complete Windows and source releases from an explicit file list."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import zipfile

from release_audit import MODEL_FILES, REPORT_FILES, audit_archive, audit_models, read_source_list, sha256

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binaries', type=Path, default=root / 'build-win64')
parser.add_argument('--policy', type=Path, help='Local JSON list of disallowed release strings')
args = parser.parse_args()
needles = json.loads(args.policy.read_text()) if args.policy else []
source_names = read_source_list(root)
model_report = audit_models(root)
name = 'SpectralAudio-win11-x64-1.0.0'
dist = root / 'dist'
dist.mkdir(exist_ok=True)

with tempfile.TemporaryDirectory(prefix='release-stage-', dir=dist) as temporary:
    stage = Path(temporary)
    payload = stage / name
    payload.mkdir()
    files = [
        *[root / entry for entry in source_names if entry.startswith('apo/') and Path(entry).suffix in ('.ps1', '.cs')],
        *[args.binaries / entry for entry in ('SpectralAudio.dll', 'spectral_apo_runtime.exe', 'spectral_apo_measure.exe', 'spectral_apo_smoke.exe', 'spectral_apo_processor_unit.exe')],
        *[root / 'models' / entry for entry in MODEL_FILES],
        *[root / entry for entry in ('model-manifest.json', 'README.md', 'THIRD_PARTY.txt', 'MINGW-COPYING', *REPORT_FILES)],
    ]
    for source in files:
        target = payload / source.name
        if target.exists():
            raise ValueError('Repeated payload filename: ' + target.name)
        shutil.copyfile(source, target)
    for action, filename in (('Install', 'Install-SpectralAudio.cmd'), ('Control', 'Open-SpectralAudio.cmd'), ('Uninstall', 'Uninstall-SpectralAudio.cmd')):
        text = '''@echo off
setlocal
title Spectral Audio
set "SpectralPS=%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
if exist "%SystemRoot%\\Sysnative\\WindowsPowerShell\\v1.0\\powershell.exe" set "SpectralPS=%SystemRoot%\\Sysnative\\WindowsPowerShell\\v1.0\\powershell.exe"
"%SpectralPS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Open-SpectralAudio.ps1" -Action ACTION
set "SpectralExit=%errorlevel%"
if not "%SpectralExit%"=="0" if not "%SpectralExit%"=="2" pause
exit /b %SpectralExit%
'''.replace('ACTION', action)
        (payload / filename).write_bytes(text.replace('\n', '\r\n').encode('ascii'))
    manifest = {file.name: sha256(file).upper() for file in sorted(payload.iterdir())}
    (payload / 'payload-sha256.json').write_text(json.dumps(manifest, indent=2) + '\n')
    runtime_zip = stage / (name + '.zip')
    with zipfile.ZipFile(runtime_zip, 'w', zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(payload.iterdir()):
            archive.write(file, arcname=name + '/' + file.name)
    with zipfile.ZipFile(runtime_zip) as archive:
        for file, digest in manifest.items():
            if hashlib.sha256(archive.read(name + '/' + file)).hexdigest().upper() != digest:
                raise ValueError('Payload hash mismatch: ' + file)
    source_zip = stage / 'SpectralAudio-source-1.0.0.zip'
    with zipfile.ZipFile(source_zip, 'w', zipfile.ZIP_DEFLATED) as archive:
        for entry in source_names:
            archive.write(root / entry, arcname='spectral-audio/' + entry)
    reports = [audit_archive(file, needles) for file in (runtime_zip, source_zip)]
    # Publish only after both complete archives pass. Rebuild the generated
    # payload directory rather than copying into a previous staging directory.
    destination = dist / name
    if destination.is_symlink():
        raise ValueError('Payload destination must not be a symlink')
    if destination.exists():
        shutil.rmtree(destination)
    shutil.move(str(payload), destination)
    for file in (runtime_zip, source_zip):
        file.replace(dist / file.name)
    result = {
        'archives': reports, 'payload_files': len(manifest), 'source_files': len(source_names),
        'manifest_verified': True, 'recursive_archive_integrity_verified': True,
        'content_policy_rules': len(needles), **model_report,
    }
    (dist / 'package-validation.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
