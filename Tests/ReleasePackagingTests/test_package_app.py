import os
from pathlib import Path
import subprocess
import sys
import textwrap
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "package-app.sh"


class PackagingArgumentTests(unittest.TestCase):
    def run_script(self, *args, env=None):
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
        )

    def assert_rejected(self, args, message):
        result = self.run_script(*args)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def test_help_has_explicit_modes_and_scope(self):
        result = self.run_script("--help")
        self.assertEqual(result.returncode, 0)
        for text in ("--unsigned-development", "--developer-id", "--notary-profile",
                     "No installation", "arm64", "macOS 15+"):
            self.assertIn(text, result.stdout)

    def test_invalid_versions(self):
        for version in ("", "v1.2.3", "1.2", "1.2.3-beta.1", "../1.2.3",
                        "01.2.3", "1.2.3\n4.5.6", "1.2.3;echo unsafe"):
            with self.subTest(version=version):
                result = self.run_script("--version", version, "--unsigned-development")
                self.assertNotEqual(result.returncode, 0)

    def test_invalid_build_numbers(self):
        for number in ("0", "-1", "01", "1.2", "one"):
            with self.subTest(number=number):
                self.assert_rejected(
                    ["--version", "1.2.3", "--build-number", number,
                     "--unsigned-development"],
                    "--build-number must be a positive integer",
                )

    def test_mode_is_required(self):
        self.assert_rejected(["--version", "1.2.3"], "explicitly")

    def test_modes_cannot_be_combined(self):
        for modes in (
            ["--unsigned-development", "--developer-id", "Developer ID Application: Test"],
            ["--developer-id", "Developer ID Application: Test", "--unsigned-development"],
            ["--unsigned-development", "--unsigned-development"],
        ):
            with self.subTest(modes=modes):
                self.assert_rejected(["--version", "1.2.3", *modes],
                                     "Choose exactly one signing mode")

    def test_notarization_profile_requires_signing(self):
        self.assert_rejected(
            ["--version", "1.2.3", "--unsigned-development", "--notary-profile", "test"],
            "--notary-profile requires --developer-id",
        )

    def test_public_mode_requires_developer_id(self):
        for identity in ("-", "Apple Development: Test", "Developer ID Installer: Test"):
            with self.subTest(identity=identity):
                self.assert_rejected(
                    ["--version", "1.2.3", "--developer-id", identity,
                     "--notary-profile", "test"],
                    "Developer ID Application identity",
                )

    def test_signing_requires_notarization(self):
        self.assert_rejected(
            ["--version", "1.2.3", "--developer-id", "Developer ID Application: Test"],
            "--developer-id requires --notary-profile",
        )

    def test_missing_values_and_unknown_arguments(self):
        for option in ("--version", "--build-number", "--output",
                       "--developer-id", "--notary-profile"):
            with self.subTest(option=option):
                self.assert_rejected([option], "Missing value")
        self.assert_rejected(["--driver"], "Unknown argument")

    def test_missing_identity_fails_before_build_without_unsigned_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            tools = Path(temporary)
            marker = tools / "build-was-started"
            stubs = {
                "uname": "#!/bin/bash\necho Darwin\n",
                "security": "#!/bin/bash\necho '0 valid identities found'\n",
                "xcodebuild": f'#!/bin/bash\ntouch "{marker}"\nexit 99\n',
                "hdiutil": "#!/bin/bash\nexit 99\n",
                "codesign": "#!/bin/bash\nexit 99\n",
                "ditto": "#!/bin/bash\nexit 99\n",
                "shasum": "#!/bin/bash\nexit 99\n",
            }
            for name, content in stubs.items():
                tool = tools / name
                tool.write_text(content)
                tool.chmod(0o755)
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")
            result = self.run_script(
                "--version", "1.2.3", "--developer-id", "Developer ID Application: Test",
                "--notary-profile", "test", "--output", str(tools / "output"), env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Signing identity is unavailable", result.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse((tools / "output").exists())

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS PlistBuddy and ditto")
    def test_rejected_notarization_never_produces_a_dmg_or_unsigned_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            tools = Path(temporary)
            identity = "Developer ID Application: Test"
            marker = tools / "dmg-was-started"
            signing_calls = tools / "signing-calls"
            stubs = {
                "uname": "print('Darwin')",
                "security": f"print('1) test \"{identity}\"')",
                "lipo": "print('arm64')",
                "hdiutil": f"Path({str(marker)!r}).touch()",
                "codesign": f"""
                    with open({str(signing_calls)!r}, 'a') as log:
                        log.write(repr(sys.argv[1:]) + '\\n')
                    if '--display' in sys.argv:
                        print('Authority={identity}', file=sys.stderr)
                """,
                "xcodebuild": """
                    args = sys.argv[1:]
                    derived = Path(args[args.index('-derivedDataPath') + 1])
                    app = derived / 'Build/Products/Release/Faderline.app/Contents'
                    (app / 'MacOS').mkdir(parents=True)
                    (app / 'MacOS/Faderline').write_bytes(b'test executable')
                    settings = dict(arg.split('=', 1) for arg in args if '=' in arg)
                    with (app / 'Info.plist').open('wb') as output:
                        plistlib.dump({
                            'CFBundleShortVersionString': settings['MARKETING_VERSION'],
                            'CFBundleVersion': settings['CURRENT_PROJECT_VERSION'],
                            'CFBundleIdentifier': 'com.faderline.app',
                            'LSMinimumSystemVersion': '15.0',
                            'NSMicrophoneUsageDescription': 'Test permission description',
                        }, output)
                """,
                "xcrun": """
                    if '--find' in sys.argv:
                        print('/mock/apple-tool')
                    elif 'history' in sys.argv:
                        pass
                    elif 'submit' in sys.argv:
                        plistlib.dump({'status': 'Invalid', 'id': 'mock-rejection'},
                                      sys.stdout.buffer)
                    else:
                        raise SystemExit('Unexpected Apple service invocation')
                """,
            }
            for name, body in stubs.items():
                tool = tools / name
                tool.write_text(
                    f"#!{sys.executable}\nimport sys, plistlib\nfrom pathlib import Path\n"
                    + textwrap.dedent(body).strip() + "\n"
                )
                tool.chmod(0o755)
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")
            output = tools / "output"
            result = self.run_script(
                "--version", "1.2.3", "--developer-id", identity,
                "--notary-profile", "mock", "--output", str(output), env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Notarization was not accepted", result.stderr)
            self.assertIn("mock-rejection", result.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse((output / "Faderline-1.2.3-arm64-developer-id-notarized").exists())
            self.assertNotIn("'--sign', '-'", signing_calls.read_text())


if __name__ == "__main__":
    unittest.main()
