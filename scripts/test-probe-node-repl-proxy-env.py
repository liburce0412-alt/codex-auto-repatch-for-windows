"""Exercise environment reads with synthetic pages and task-owned subprocesses."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("probe-node-repl-proxy-env.py")
spec = importlib.util.spec_from_file_location("proxy_probe", SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def memory(data, region_sizes=None):
    sizes = region_sizes or [len(data)]
    ends = []
    for size in sizes:
        ends.append((ends[-1] if ends else 0) + size)

    def read(address, count):
        offset = address - 0x1000
        for end in ends:
            if offset < end:
                return data[offset:min(offset + count, end)]
        raise RuntimeError("Unreadable next memory region")
    return read


class ProbeTests(unittest.TestCase):
    def test_optional_proxy_names_do_not_hide_required_names(self):
        raw = ("\0".join(f"{name}=private" for name in probe.PROXY_NAMES) + "\0\0").encode("utf-16-le")
        names = probe.read_environment(memory(raw), 0x1000)
        self.assertEqual(names, list(probe.PROXY_NAMES))
        self.assertTrue({"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"}.issubset(names))
        self.assertEqual(len(names), 6)

    def test_long_environment(self):
        raw = ("AAA=" + "x" * 20000 + "\0https_proxy=private-value\0NO_PROXY=localhost\0\0").encode("utf-16-le")
        self.assertEqual(probe.read_environment(memory(raw), 0x1000), ["HTTPS_PROXY", "NO_PROXY"])

    def test_terminator_spans_regions(self):
        raw = "HTTPS_PROXY=private\0\0".encode("utf-16-le")
        self.assertEqual(probe.read_environment(memory(raw, [len(raw) - 2, 2]), 0x1000), ["HTTPS_PROXY"])

    def test_regions_split_entries(self):
        raw = "A=value\0WS_PROXY=private\0\0".encode("utf-16-le")
        self.assertEqual(probe.read_environment(memory(raw, [6, 10, len(raw) - 16]), 0x1000), ["WS_PROXY"])

    def test_no_proxy_and_drive_entry(self):
        raw = "=C:=C:\\work\0A=1\0\0".encode("utf-16-le")
        self.assertEqual(probe.read_environment(memory(raw), 0x1000), [])
        self.assertEqual(probe.read_environment(memory(b"\0" * 4), 0x1000), [])

    def test_unaligned_zero_sequence(self):
        raw = "A=x\0\u0100=value\0HTTPS_PROXY=private\0\0".encode("utf-16-le")
        self.assertEqual(probe.read_environment(memory(raw), 0x1000), ["HTTPS_PROXY"])

    def test_incomplete_and_limit(self):
        raw = "HTTPS_PROXY=private\0".encode("utf-16-le")
        with self.assertRaisesRegex(RuntimeError, "Unreadable"):
            probe.read_environment(memory(raw), 0x1000)
        with self.assertRaisesRegex(RuntimeError, "limit"):
            probe.read_environment(memory(raw), 0x1000, len(raw))
        with self.assertRaisesRegex(RuntimeError, "Incomplete"):
            probe.read_environment(lambda address, count: b"", 0x1000)
        with self.assertRaisesRegex(RuntimeError, "Incomplete"):
            probe.read_environment(lambda address, count: b"x", 0x1000)

    def test_invalid_text_does_not_leak_values(self):
        for raw in [b"\0\xd8\0\0\0\0", "private-malformed\0\0".encode("utf-16-le")]:
            with self.assertRaises(RuntimeError) as context:
                probe.read_environment(memory(raw), 0x1000)
            self.assertNotIn("private", str(context.exception))

    def test_invalid_pointer(self):
        for address in [0, 0x1001]:
            with self.assertRaisesRegex(RuntimeError, "pointer"):
                probe.read_environment(memory(b"\0" * 4), address)

    def test_pointer_read_spans_regions(self):
        raw = (0x123456789).to_bytes(8, "little")
        self.assertEqual(probe.read_exact(memory(raw, [4, 4]), 0x1000, 8), raw)
        with self.assertRaises(RuntimeError):
            probe.read_exact(memory(raw[:4]), 0x1000, 8)

    @unittest.skipUnless(sys.platform == "win32", "Windows process test")
    def test_native_short_and_long_processes(self):
        for padding in [0, 20000]:
            env = {key: value for key, value in os.environ.items() if key.upper() not in probe.PROXY_NAMES}
            env["AAA_PROXY_PROBE_PADDING"] = "x" * padding
            env["HTTPS_PROXY"] = "http://private-probe-value.invalid:12345"
            with subprocess.Popen([sys.executable, "-u", "-c", "import os,sys; print('HTTPS_PROXY' in os.environ,flush=True); sys.stdin.readline()"],
                                  env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as child:
                try:
                    self.assertEqual(child.stdout.readline().strip(), "True")
                    result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--pid", str(child.pid)], capture_output=True, text=True, timeout=20)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    report = json.loads(result.stdout)
                    self.assertTrue(report["complete"])
                    self.assertEqual(report["proxyKeysPresent"], ["HTTPS_PROXY"])
                    self.assertNotIn("private-probe-value", result.stdout + result.stderr)
                finally:
                    child.communicate("exit\n", timeout=10)

    @unittest.skipUnless(sys.platform == "win32", "Windows process test")
    def test_invalid_pid_fails_without_absence_claim(self):
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--pid", "-1"], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertFalse(report["complete"])
        self.assertNotIn("proxyKeysPresent", report)


if __name__ == "__main__":
    unittest.main(verbosity=2)
