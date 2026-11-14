from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SOURCE = (Path(__file__).resolve().parents[1] / 'tf2vr').read_text()
FUNCTION = SOURCE.split('ea_running() {', 1)[1].split('\nEA_DATA=', 1)[0]
SCAN = FUNCTION.split("<<'PYEA'\n", 1)[1].split('\nPYEA', 1)[0]


class EaProcessDetectionTests(unittest.TestCase):
    def scan(self, *commands):
        with tempfile.TemporaryDirectory() as temporary:
            paths = []
            for index, command in enumerate(commands):
                path = Path(temporary) / str(index)
                path.write_bytes(command)
                paths.append(str(path))
            paths.insert(0, str(Path(temporary) / 'vanished-process'))
            with patch('glob.glob', return_value=paths):
                with self.assertRaises(SystemExit) as result:
                    exec(compile(SCAN, 'ea_running', 'exec'), {})
            return result.exception.code

    def test_windows_executable(self):
        self.assertEqual(self.scan(b'C:\\Program Files\\EA Desktop\\EADesktop.exe\0--arg\0'), 0)

    def test_unix_executable_and_case(self):
        self.assertEqual(self.scan(b'/prefix/EA Desktop/eadesktop.EXE\0'), 0)

    def test_does_not_match_arguments_or_other_executables(self):
        self.assertEqual(self.scan(b'python3\0C:\\EADesktop.exe\0',
                                   b'C:\\NotEADesktop.exe\0', b''), 1)

    def test_process_disappearing_does_not_fail_scan(self):
        self.assertEqual(self.scan(), 1)


if __name__ == '__main__':
    unittest.main()
