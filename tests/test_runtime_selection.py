import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


LAUNCHER = (Path(__file__).resolve().parents[1] / 'tf2vr').read_text()
SELECTION = LAUNCHER[LAUNCHER.index('# Only SteamVR needs starting here;'):
                     LAUNCHER.index('export TF2VR_OPENXR=1')]


class RuntimeSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'bin').mkdir()
        (self.root / 'bin/python3').symlink_to(sys.executable)
        self.config = self.root / 'config'
        self.runtime = self.root / 'runtime.json'
        self.runtime.write_text(json.dumps({'runtime': {'name': 'External runtime', 'library_path': 'lib.so'}}))
        (self.root / 'lib.so').touch()
        self.bridge = self.root / 'bridge'
        (self.bridge / 'bin/linux64').mkdir(parents=True)
        (self.bridge / 'bin/linux64/vrclient.so').touch()
        (self.config / 'openxr/1').mkdir(parents=True)
        (self.config / 'openxr/1/active_runtime.json').symlink_to(self.runtime)
        (self.config / 'openvr').mkdir()
        self.paths = self.config / 'openvr/openvrpaths.vrpath'
        self.paths.write_text(json.dumps({'runtime': [str(self.bridge)]}))

    def run_selection(self, **overrides):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('XR_', 'VR_', 'TF2VR_'))}
        env.update(HOME=str(self.root), XDG_CONFIG_HOME=str(self.config),
                   XDG_DATA_HOME=str(self.root / 'data'), LOG_DIR=str(self.root),
                   PATH=str(self.root / 'bin') + os.pathsep + env['PATH'])
        env.update({k: str(v) for k, v in overrides.items()})
        script = 'set -u\ndie() { echo "ERROR: $*"; exit 1; }\n' + SELECTION
        script += '\nprintf "SELECTED=%s|%s|%s\\n" "$RUNTIME_JSON" "${XR_RUNTIME_JSON:-}" "${VR_PATHREG_OVERRIDE:-}"\n'
        return subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True, timeout=5)

    def test_default_registration(self):
        result = self.run_selection()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('OpenVR bridge: ' + str(self.bridge), result.stdout)

    def test_explicit_openxr_overrides_default_and_survives(self):
        other = self.root / 'explicit.json'
        other.write_text(self.runtime.read_text())
        result = self.run_selection(XR_RUNTIME_JSON=other)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'SELECTED={other}|{other}|', result.stdout)

    def test_missing_explicit_openxr_does_not_fall_back(self):
        result = self.run_selection(XR_RUNTIME_JSON=self.root / 'missing.json')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('XR_RUNTIME_JSON points at a missing runtime', result.stdout)

    def test_explicit_openvr_registry_survives(self):
        other = self.root / 'paths.json'
        other.write_text(self.paths.read_text())
        result = self.run_selection(VR_PATHREG_OVERRIDE=other)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('|' + str(other), result.stdout)

    def test_invalid_explicit_registry_fails(self):
        other = self.root / 'broken.json'
        other.write_text('{}')
        result = self.run_selection(VR_PATHREG_OVERRIDE=other)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Invalid VR_PATHREG_OVERRIDE', result.stdout)

    def test_explicit_bridge_precedes_registry(self):
        other = self.root / 'other-bridge'
        (other / 'bin/linux64').mkdir(parents=True)
        (other / 'bin/linux64/vrclient.so').touch()
        result = self.run_selection(VR_OVERRIDE=other)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        saved = json.loads((self.root / 'openvrpaths.vrpath').read_text())
        self.assertEqual(saved['runtime'], [str(other)])
        self.assertEqual(json.loads(self.paths.read_text())['runtime'], [str(self.bridge)])

    def test_invalid_explicit_bridge_fails(self):
        result = self.run_selection(VR_OVERRIDE=self.root / 'missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('VR_OVERRIDE has no', result.stdout)


if __name__ == '__main__':
    unittest.main()
