import contextlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/verify-build-environment.py"
SPEC = importlib.util.spec_from_file_location("build_environment", SCRIPT)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)
EXPECTED = {
    "EXPECTED_XCODE_VERSION": "26.6",
    "EXPECTED_XCODE_BUILD": "17F113",
    "EXPECTED_DTXCODE": "2660",
    "EXPECTED_MACOS_SDK_VERSION": "26.5",
    "EXPECTED_SWIFT_VERSION": "6.3.3",
    "EXPECTED_SWIFT_BUILD": "swiftlang-6.3.3.1.3",
}


class BuildEnvironmentTests(unittest.TestCase):
    def setUp(self):
        output = io.StringIO()
        self.addCleanup(output.close)
        contexts = contextlib.ExitStack()
        self.addCleanup(contexts.close)
        contexts.enter_context(contextlib.redirect_stdout(output))
        contexts.enter_context(contextlib.redirect_stderr(output))

    def tool_output(self, *args):
        return {
            ("sw_vers", "-productVersion"): "26.6.2",
            ("sw_vers", "-buildVersion"): "25G83",
            ("uname", "-m"): "arm64",
            ("xcodebuild", "-version"): "Xcode 26.6\nBuild version 17F113",
            ("xcrun", "--sdk", "macosx", "--show-sdk-version"): "26.5",
            ("swift", "--version"): (
                "Apple Swift version 6.3.3 "
                "(swiftlang-6.3.3.1.3 clang-2100.1.1.101)\n"
                "Target: arm64-apple-macosx26.0\n"
                "swift-driver version: 1.148.6"
            ),
        }[args]

    def test_selected_stable_toolchain(self):
        with patch.object(VERIFY, "command", side_effect=self.tool_output):
            VERIFY.verify_toolchain(EXPECTED)

    def test_wrong_xcode_build_sdk_or_host_fails(self):
        for args, wrong in (
            (("xcodebuild", "-version"), "Xcode 16.4\nBuild version 16F6"),
            (("xcodebuild", "-version"), "Xcode 26.6\nBuild version 17F999"),
            (("xcodebuild", "-version"), "Xcode 27.2 beta\nBuild version 18B1"),
            (("xcrun", "--sdk", "macosx", "--show-sdk-version"), "15.5"),
            (("uname", "-m"), "x86_64"),
        ):
            with self.subTest(args=args, wrong=wrong):
                def output(*command):
                    return wrong if command == args else self.tool_output(*command)
                with patch.object(VERIFY, "command", side_effect=output):
                    with self.assertRaises(ValueError):
                        VERIFY.verify_toolchain(EXPECTED)

    def test_wrong_swift_version_build_or_output_fails(self):
        for wrong in (
            "Apple Swift version 6.4 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)",
            "Apple Swift version 6.3.3 (swiftlang-6.3.3.99.1 clang-2100.1.1.101)",
            "Apple Swift version 6.3.3-dev (swiftlang-6.3.3.1.3 clang-2100.1.1.101)",
            "Swift version 6.3.3 (swift-6.3.3-RELEASE)",
            "Apple Swift version 6.3.3",
            "",
        ):
            with self.subTest(wrong=wrong):
                def output(*args):
                    return wrong if args == ("swift", "--version") else self.tool_output(*args)
                with patch.object(VERIFY, "command", side_effect=output):
                    with self.assertRaises(ValueError):
                        VERIFY.verify_toolchain(EXPECTED)

    def test_mismatched_path_swift_returns_failure(self):
        def output(*args):
            if args == ("swift", "--version"):
                return "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)"
            return self.tool_output(*args)
        with patch.dict(os.environ, EXPECTED, clear=True):
            with patch.object(VERIFY.sys, "argv", [str(SCRIPT)]):
                with patch.object(VERIFY, "command", side_effect=output) as command:
                    self.assertEqual(VERIFY.main(), 1)
                    command.assert_any_call("swift", "--version")

    def test_workflows_share_toolchain_pins(self):
        for filename in ("macos.yml", "release.yml"):
            with self.subTest(filename=filename):
                workflow = (ROOT / ".github/workflows" / filename).read_text()
                pins = dict(re.findall(r"^      (EXPECTED_\w+): '([^']+)'$",
                                       workflow, re.MULTILINE))
                self.assertEqual(pins, EXPECTED)

    def test_release_tests_support_old_tags_without_dependency_fallback(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Build package and run repository tests\n", 1)[1]
        step = step.split("\n      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        self.assertIn("if: ${{ hashFiles('scripts/packaging-requirements.txt') != '' }}",
                      workflow)
        for modern, venv in ((False, False), (True, True), (True, False)):
            with self.subTest(modern=modern, venv=venv):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    tools = root / "tools"
                    tools.mkdir()
                    calls = root / "calls.txt"
                    for name in ("swift", "python3", ".build/packaging-venv/bin/python"):
                        if name.startswith(".build") and not venv:
                            continue
                        tool = root / name if name.startswith(".build") else tools / name
                        tool.parent.mkdir(parents=True, exist_ok=True)
                        tool.write_text(
                            f"#!{VERIFY.sys.executable}\n"
                            "from pathlib import Path\n"
                            f"with Path({str(calls)!r}).open('a') as output:\n"
                            f"    output.write({name!r} + '\\n')\n"
                        )
                        tool.chmod(0o755)
                    if modern:
                        (root / "scripts").mkdir()
                        (root / "scripts/packaging-requirements.txt").touch()
                    result = subprocess.run(
                        ["bash", "-euo", "pipefail", "-c", script], cwd=root,
                        env=dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}"),
                        capture_output=True, text=True,
                    )
                    actual = calls.read_text().splitlines()
                    if modern and not venv:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertNotIn("python3", actual)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        expected_python = ".build/packaging-venv/bin/python" if modern else "python3"
                        self.assertEqual(actual, ["swift"] * 3 + [expected_python, "python3"])

    def metadata(self):
        return {
            "CFBundleIdentifier": "com.faderline.app",
            "CFBundleExecutable": "Faderline",
            "DTSDKName": "macosx26.5",
            "DTXcode": "2660",
            "DTXcodeBuild": "17F113",
            "LSMinimumSystemVersion": "15.0",
        }

    def check_bundle(self, metadata, architecture="arm64"):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Faderline.app"
            (app / "Contents").mkdir(parents=True)
            with (app / "Contents/Info.plist").open("wb") as destination:
                plistlib.dump(metadata, destination)
            with patch.object(VERIFY, "command", return_value=architecture) as command:
                VERIFY.verify_app(app, EXPECTED)
                command.assert_called_once_with(
                    "lipo", "-archs", str(app / "Contents/MacOS/Faderline")
                )

    def test_built_app_metadata_and_arm64(self):
        self.check_bundle(self.metadata())

    def test_wrong_or_missing_metadata_fails(self):
        for key, value in self.metadata().items():
            for wrong in (None, f"{value}-wrong"):
                with self.subTest(key=key, wrong=wrong):
                    metadata = self.metadata()
                    if wrong is None:
                        del metadata[key]
                    else:
                        metadata[key] = wrong
                    with self.assertRaises(ValueError):
                        self.check_bundle(metadata)

    def test_intel_and_universal_bundles_fail(self):
        for architecture in ("x86_64", "arm64 x86_64"):
            with self.subTest(architecture=architecture):
                with self.assertRaises(ValueError):
                    self.check_bundle(self.metadata(), architecture)

    def test_unset_expectation_fails_before_tool_invocation(self):
        for key in EXPECTED:
            env = dict(EXPECTED)
            del env[key]
            with self.subTest(key=key), patch.dict(os.environ, env, clear=True):
                with patch.object(VERIFY.sys, "argv", [str(SCRIPT)]):
                    with patch.object(VERIFY, "command") as command:
                        self.assertEqual(VERIFY.main(), 1)
                        command.assert_not_called()

    def test_failed_tool_command_is_not_success(self):
        with patch.dict(os.environ, EXPECTED, clear=True):
            with patch.object(VERIFY.sys, "argv", [str(SCRIPT)]):
                with patch.object(
                    VERIFY, "command",
                    side_effect=subprocess.CalledProcessError(1, ["xcodebuild"]),
                ):
                    self.assertEqual(VERIFY.main(), 1)


if __name__ == "__main__":
    unittest.main()
