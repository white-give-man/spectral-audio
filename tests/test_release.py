"""Regression checks for release contents and nested model containers."""
import io
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from release_audit import read_source_list, scan_bytes


def archive(name, data):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as value:
        value.writestr(name, data)
    return output.getvalue()


class ReleaseTests(unittest.TestCase):
    def test_nested_model_metadata_is_scanned(self):
        data = archive('models/weights.pt', archive('weights/data.pkl', b'EXCLUDED_METADATA'))
        with self.assertRaisesRegex(ValueError, 'data.pkl'):
            scan_bytes('release.zip', data, ['EXCLUDED_METADATA'])

    def test_nested_model_member_names_are_scanned(self):
        data = archive('model.ts', archive('code/EXCLUDED_MODULE.py', b'pass'))
        with self.assertRaises(ValueError):
            scan_bytes('source.zip', data, ['EXCLUDED_MODULE'])

    def test_utf16_binary_strings_are_scanned(self):
        with self.assertRaises(ValueError):
            scan_bytes('plugin.dll', b'\x00' + 'EXCLUDED_PATH'.encode('utf-16le'), ['EXCLUDED_PATH'])

    def test_unlisted_source_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'release-files.json').write_text('{"source_files":["release-files.json"]}')
            (root / 'unlisted-file.json').write_text('{}')
            with self.assertRaises(ValueError):
                read_source_list(root)

    def test_clean_nested_models_pass(self):
        self.assertGreater(scan_bytes('release.zip', archive('model.ts', archive('code/predictor.py', b'pass')), ['EXCLUDED_MODULE']), 2)


if __name__ == '__main__':
    unittest.main()
