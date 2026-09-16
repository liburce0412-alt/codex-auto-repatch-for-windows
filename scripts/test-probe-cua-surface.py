"""Offline response-validation tests; never launch a server or inspect real user windows."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "probe_cua_surface", Path(__file__).with_name("probe-cua-surface.py")
)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProbeValidationTests(unittest.TestCase):
    def run_probe(self, *, keys="CUA_KEYS=computer,getApp,listApps",
                  windows="WINDOWS=windows/2", inventory="APPS=4 BROWSERS=1",
                  description=None, skip_inventory=False):
        if description is None:
            description = "\n".join(probe.GUIDANCE_TOKENS)
        responses = [description, "banner consumed", keys]
        if not skip_inventory:
            responses.extend([windows, inventory])
        argv = ["probe-cua-surface.py"] + (["--skip-inventory"] if skip_inventory else [])
        output = io.StringIO()
        with (
            mock.patch.object(sys, "argv", argv),
            mock.patch.object(probe, "find_mcp_json", return_value="fixture/.mcp.json"),
            mock.patch.object(probe, "read_server_config", return_value={}),
            mock.patch.object(probe, "start_server", return_value=(object(), "browser")),
            mock.patch.object(probe, "run_calls", return_value=(responses, [])) as calls,
            contextlib.redirect_stdout(output),
        ):
            code = probe.main()
        return code, output.getvalue(), calls.call_args.args[1]

    def test_positive_inventory(self):
        code, output, steps = self.run_probe()
        self.assertEqual(code, 0)
        self.assertIn("result        : ok", output)
        self.assertEqual(len(steps), 5)

    def test_empty_windows(self):
        self.assertEqual(self.run_probe(windows="WINDOWS=windows/0")[0], 1)

    def test_invalid_window_results(self):
        for result in ("", "ERROR tool failed", "WINDOWS=mac/2", "WINDOWS=windows/-1",
                       "WINDOWS=windows/nope", "WINDOWS=windows/2 trailing"):
            with self.subTest(result=result):
                self.assertEqual(self.run_probe(windows=result)[0], 1)

    def test_missing_application_response(self):
        self.assertEqual(self.run_probe(inventory="")[0], 1)

    def test_empty_application_inventory(self):
        self.assertEqual(self.run_probe(inventory="APPS=0 BROWSERS=1")[0], 1)

    def test_invalid_application_results(self):
        for result in ("ERROR tool failed", "APPS=3", "APPS=-1 BROWSERS=2",
                       "APPS=3 BROWSERS=nope", "APPS=3 BROWSERS=1 trailing"):
            with self.subTest(result=result):
                self.assertEqual(self.run_probe(inventory=result)[0], 1)

    def test_required_member_must_match_exactly(self):
        self.assertEqual(self.run_probe(keys="CUA_KEYS=computer,getApp,listAppsSuffix")[0], 1)

    def test_missing_keys(self):
        self.assertEqual(self.run_probe(keys="")[0], 1)

    def test_whitespace_between_members(self):
        self.assertEqual(self.run_probe(keys="CUA_KEYS=computer, getApp, listApps")[0], 0)

    def test_echoed_source_is_not_a_result(self):
        code = "nodeRepl.write('CUA_KEYS=computer,getApp,listApps')"
        self.assertEqual(self.run_probe(keys=code)[0], 1)

    def test_guidance_is_required(self):
        self.assertEqual(self.run_probe(description="macOS-only guidance")[0], 1)

    def test_skip_inventory_is_explicit(self):
        code, output, steps = self.run_probe(skip_inventory=True)
        self.assertEqual(code, 0)
        self.assertEqual(len(steps), 3)
        self.assertNotIn("windows api", output)

    def test_extract_ignores_banner_and_preserves_crlf(self):
        text = "documentation\r\nWINDOWS=windows/3\r\nfooter\r\n"
        self.assertEqual(probe.extract(text, "WINDOWS="), "windows/3")

    def test_non_positive_timeout_is_rejected_before_launch(self):
        with mock.patch.object(sys, "argv", ["probe-cua-surface.py", "--timeout", "0"]):
            with mock.patch.object(probe, "start_server") as start:
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as result:
                        probe.main()
                self.assertEqual(result.exception.code, 2)
                start.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
