"""Audit explicit release file lists and recursively inspect model/archive members."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import zipfile

MODEL_FILES = ('predictor.ts', 'predictor.pt', 'predictor.norm.npz', 'filterbanks.npz')
REPORT_FILES = (
    'validation-model.json', 'validation-windows.json',
    'validation-package.json', 'validation-model-containers.json',
)
ROOT_FILES = (
    '.gitignore', 'CMakeLists.txt', 'MINGW-COPYING', 'README.md',
    'THIRD_PARTY.txt', 'model-manifest.json', 'release-files.json',
    *REPORT_FILES,
)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_source_list(root):
    names = json.loads((root / 'release-files.json').read_text())['source_files']
    if len(set(names)) != len(names):
        raise ValueError('Repeated source release entry')
    for name in names:
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or not (root / path).is_file():
            raise ValueError('Invalid source release entry: ' + name)
    # Fail on unlisted files in the release tree, excluding build products.
    discovered = set()
    for path in root.rglob('*'):
        relative = path.relative_to(root)
        if relative.parts[0].startswith('build') or any(part in ('dist', '__pycache__', '.git') for part in relative.parts):
            continue
        if path.is_file():
            discovered.add(relative.as_posix())
    if discovered != set(names):
        raise ValueError('Source release list differs from files on disk: ' + repr(sorted(discovered.symmetric_difference(names))))
    return names


def audit_models(root):
    report = json.loads((root / 'validation-model-containers.json').read_text())
    if report['checkpoint_keys'] != ['hidden', 'mean', 'state_dict', 'std']:
        raise ValueError('Unexpected checkpoint metadata schema')
    if not report['tensor_values_exact'] or not report['torchscript_outputs_and_states_exact'] or report['debug_records_included']:
        raise ValueError('Model export validation is incomplete')
    manifest = json.loads((root / 'model-manifest.json').read_text())['files']
    for name in MODEL_FILES:
        digest = sha256(root / 'models' / name)
        if digest != manifest[name] or digest != report['files'][name]:
            raise ValueError('Model file changed after validation: ' + name)
    with zipfile.ZipFile(root / 'models/predictor.ts') as archive:
        user_modules = []
        for name in archive.namelist():
            if name.endswith('.debug_pkl') or '/traced_inputs' in name:
                raise ValueError('Unexpected model debug record')
            if '/code/__torch__/' in name and '/torch/' not in name:
                user_modules.append(name.split('/code/__torch__/', 1)[1])
        if user_modules != ['spectral_predictor.py']:
            raise ValueError('Unexpected predictor module schema')
    return {'model_files_verified': len(MODEL_FILES), 'checkpoint_schema_verified': True, 'predictor_module_verified': True}


def scan_bytes(label, data, needles=(), depth=0):
    """Scan UTF-8/UTF-16 names and contents, including nested ZIP-based models."""
    if depth > 8:
        raise ValueError('Archive nesting limit exceeded: ' + label)
    matches = []
    for index, needle in enumerate(needles):
        if any(value.lower() in data.lower() for value in (needle.encode('utf-8'), needle.encode('utf-16le'), needle.encode('utf-16be'))):
            matches.append(index)
    if matches:
        raise ValueError('Release content policy matched at ' + label + ': rule indexes ' + repr(matches))
    members = 1
    stream = io.BytesIO(data)
    if zipfile.is_zipfile(stream):
        stream.seek(0)
        with zipfile.ZipFile(stream) as archive:
            if archive.testzip() is not None:
                raise ValueError('Archive integrity failure: ' + label)
            for member in archive.infolist():
                if member.flag_bits & 1:
                    raise ValueError('Encrypted release entry: ' + label)
                scan_bytes(label + ' (entry name)', member.filename.encode('utf-8'), needles, depth + 1)
                members += scan_bytes(label + '!' + member.filename, archive.read(member.filename), needles, depth + 1)
    return members


def audit_archive(path, needles=()):
    return {'archive': path.name, 'sha256': sha256(path), 'members_scanned': scan_bytes(path.name, path.read_bytes(), needles), 'content_policy_matches': 0}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archives', nargs='+', type=Path)
    parser.add_argument('--policy', type=Path, help='Local JSON list of disallowed release strings')
    args = parser.parse_args()
    needles = json.loads(args.policy.read_text()) if args.policy else []
    print(json.dumps([audit_archive(path, needles) for path in args.archives], indent=2))
