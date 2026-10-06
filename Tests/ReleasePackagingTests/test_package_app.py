import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import textwrap
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "package-app.sh"


def workflow_step_script(workflow, name):
    marker = f"      - name: {name}\n"
    step = workflow.split(marker, 1)[1].split("\n      - name:", 1)[0]
    return textwrap.dedent(step.split("        run: |\n", 1)[1])


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

    def test_public_signing_entitlements_allow_audio_without_sandboxing(self):
        with (ROOT / "scripts/DeveloperID.entitlements").open("rb") as source:
            entitlements = plistlib.load(source)
        self.assertEqual(entitlements, {"com.apple.security.device.audio-input": True})

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS signing tools")
    def test_codesign_xml_preserves_audio_input_with_hardened_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = str(Path(temporary) / "entitlement-test")
            compiled = subprocess.run(
                ["clang", "-x", "c", "-", "-o", executable],
                input="int main(void) { return 0; }\n",
                capture_output=True, text=True,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            signed = subprocess.run(
                ["codesign", "--force", "--sign", "-", "--options", "runtime",
                 "--timestamp=none", "--entitlements",
                 str(ROOT / "scripts/DeveloperID.entitlements"), executable],
                capture_output=True, text=True,
            )
            self.assertEqual(signed.returncode, 0, signed.stderr)
            displayed = subprocess.run(
                ["codesign", "--display", "--entitlements", "-", "--xml", executable],
                capture_output=True,
            )
            self.assertEqual(displayed.returncode, 0, displayed.stderr)
            self.assertEqual(
                plistlib.loads(displayed.stdout),
                {"com.apple.security.device.audio-input": True},
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
                    if '--display' in sys.argv and '--entitlements' in sys.argv:
                        if '--xml' in sys.argv:
                            plistlib.dump({{'com.apple.security.device.audio-input': True}},
                                          sys.stdout.buffer)
                        else:
                            print('[Dict] human-readable entitlements')
                    elif '--display' in sys.argv:
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


class ReleaseTitleTests(unittest.TestCase):
    def test_unsigned_label_preserves_release_name_or_falls_back_to_tag(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        script = workflow_step_script(workflow, "Label unsigned development release")
        banner = (
            "**Unsigned development artifacts: NOT Developer ID signed or notarized. "
            "macOS Gatekeeper may block these builds.**"
        )
        for title, expected, notes in (
            ("", "v1.2.3 (unsigned development)", "Original release notes"),
            ("Custom title", "Custom title (unsigned development)", "Original release notes"),
            ("v1.2.3 (unsigned development)", "v1.2.3 (unsigned development)",
             f"{banner}\n\nOriginal release notes"),
        ):
            with self.subTest(title=title), tempfile.TemporaryDirectory() as temporary:
                tools = Path(temporary)
                gh = tools / "gh"
                gh.write_text(
                    f"#!{sys.executable}\n"
                    + textwrap.dedent("""
                        import json, os, sys
                        from pathlib import Path
                        args = sys.argv[1:]
                        if args[:2] == ['release', 'view']:
                            field = args[args.index('--json') + 1]
                            print(os.environ['RELEASE_TITLE'] if field == 'name'
                                  else os.environ['RELEASE_NOTES'])
                        elif args[:2] == ['release', 'edit']:
                            Path(os.environ['EDIT_CAPTURE']).write_text(json.dumps(args))
                        else:
                            raise SystemExit('Unexpected GitHub call')
                    """)
                )
                gh.chmod(0o755)
                capture = tools / "edit.json"
                env = dict(
                    os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                    TAG="v1.2.3", RUNNER_TEMP=str(tools),
                    RELEASE_TITLE=title, RELEASE_NOTES=notes, EDIT_CAPTURE=str(capture),
                )
                result = subprocess.run(
                    ["bash", "-euo", "pipefail", "-c", script],
                    env=env, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads(capture.read_text())
                self.assertEqual(args[args.index("--title") + 1], expected)
                self.assertIn("--prerelease", args)
                updated_notes = (tools / "release-notes.md").read_text()
                self.assertEqual(updated_notes.count(banner), 1)
                self.assertIn("Original release notes", updated_notes)


class ReleaseAssetUploadTests(unittest.TestCase):
    def setUp(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.script = workflow_step_script(
            workflow, "Attach DMG and checksum to GitHub Release"
        )

    def run_upload(self, temporary, dmg_count):
        root = Path(temporary)
        tools = root / "tools"
        tools.mkdir()
        capture = root / "upload.json"
        gh = tools / "gh"
        gh.write_text(
            f"#!{sys.executable}\n"
            + textwrap.dedent("""
                import json, os, sys
                from pathlib import Path
                Path(os.environ['UPLOAD_CAPTURE']).write_text(
                    json.dumps(sys.argv[1:])
                )
            """)
        )
        gh.chmod(0o755)

        package = root / "dist" / "Faderline-1.2.3-arm64-developer-id-notarized"
        package.mkdir(parents=True)
        for index in range(dmg_count):
            (package / f"package-{index}.dmg").write_bytes(
                f"verified package {index}".encode()
            )

        env = dict(
            os.environ,
            PATH=f"{tools}:{os.environ['PATH']}",
            TAG="v1.2.3",
            RUNNER_TEMP=str(root / "runner"),
            UPLOAD_CAPTURE=str(capture),
        )
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", self.script],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
        )
        return result, root, capture

    def test_upload_uses_normalized_names_and_matching_checksum(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, root, capture = self.run_upload(temporary, 1)
            self.assertEqual(result.returncode, 0, result.stderr)

            assets = root / "runner" / "release-assets"
            dmg = assets / "Faderline-1.2.3.dmg"
            checksum = assets / "Faderline-1.2.3.sha256"
            self.assertTrue(dmg.is_file())
            self.assertTrue(checksum.is_file())
            self.assertEqual(dmg.read_bytes(), b"verified package 0")
            self.assertEqual(
                subprocess.run(
                    ["shasum", "-a", "256", "-c", checksum.name],
                    cwd=assets, capture_output=True, text=True,
                ).returncode,
                0,
            )

            args = json.loads(capture.read_text())
            self.assertEqual(
                args,
                [
                    "release", "upload", "v1.2.3", str(dmg), str(checksum),
                    "--clobber",
                ],
            )
            self.assertNotIn("arm64", " ".join(args))
            self.assertNotIn("notarized", " ".join(args))

    def test_upload_rejects_zero_or_multiple_dmgs(self):
        for dmg_count in (0, 2):
            with self.subTest(dmg_count=dmg_count), tempfile.TemporaryDirectory() as temporary:
                result, root, capture = self.run_upload(temporary, dmg_count)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Expected exactly one packaged DMG", result.stderr)
                self.assertFalse(capture.exists())
                self.assertFalse((root / "runner" / "release-assets").exists())

    def test_signed_status_is_updated_after_package_and_before_upload(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        label = workflow.index("      - name: Label signed release\n")
        upload = workflow.index("      - name: Attach DMG and checksum to GitHub Release\n")
        package = workflow.index("      - name: Package Developer ID signed and notarized DMG\n")
        self.assertGreater(label, package)
        self.assertLess(label, upload)


if __name__ == "__main__":
    unittest.main()
