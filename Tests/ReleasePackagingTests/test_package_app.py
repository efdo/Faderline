import json
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import textwrap
import tempfile
import unittest
from unittest.mock import patch

from ds_store import DSStore
from mac_alias import Alias


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "package-app.sh"
spec = importlib.util.spec_from_file_location("presentation", ROOT / "scripts/dmg-presentation.py")
presentation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(presentation)


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
        step = workflow.split("      - name: Label unsigned development release\n", 1)[1]
        step = step.split("\n      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
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


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS disk images and AppKit")
class FinderPresentationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.mount = self.directory / "mount"
        self.mount.mkdir()
        self.volume = "Faderline 1.2.3 - UNSIGNED DEVELOPMENT"
        self.run_tool("hdiutil", "create", "-quiet", "-size", "32m",
                      "-fs", "HFS+", "-volname", self.volume,
                      str(self.directory / "test.dmg"))
        self.run_tool("hdiutil", "attach", "-quiet", "-nobrowse",
                      "-mountpoint", str(self.mount), str(self.directory / "test.dmg"))
        self.addCleanup(self.run_tool, "hdiutil", "detach", "-quiet", str(self.mount))
        (self.mount / "Faderline.app").mkdir()
        (self.mount / "Applications").symlink_to("/Applications")
        presentation.write_presentation(self.mount, "unsigned-development")

    def run_tool(self, *args):
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def verify(self):
        presentation.verify_presentation(self.mount, "unsigned-development", self.volume)

    def test_exact_layout_and_volume_relative_background(self):
        self.verify()
        with DSStore.open(str(self.mount / ".DS_Store"), "r") as store:
            self.assertEqual(store["."]["bwsp"]["WindowBounds"], "{{200, 160}, {560, 340}}")
            for setting in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar",
                            "ShowTabView", "ContainerShowSidebar", "PreviewPaneVisibility"):
                self.assertFalse(store["."]["bwsp"][setting])
            self.assertEqual(store["."]["icvl"], (b"type", b"icnv"))
            self.assertEqual(store["."]["icvp"]["iconSize"], 96.0)
            self.assertEqual(store["."]["icvp"]["arrangeBy"], "none")
            self.assertEqual(store["Faderline.app"]["Iloc"], (150, 162))
            self.assertEqual(store["Applications"]["Iloc"], (410, 162))
            alias = Alias.from_bytes(store["."]["icvp"]["backgroundImageAlias"])
            self.assertEqual(alias.target.posix_path, "/.background.tiff")
            self.assertEqual(alias.target.cnid, (self.mount / ".background.tiff").stat().st_ino)
        self.assertEqual(
            {item.name for item in self.mount.iterdir() if not item.name.startswith(".")},
            {"Faderline.app", "Applications"},
        )
        dimensions = self.run_tool("sips", "-g", "pixelWidth", "-g", "pixelHeight",
                                   str(self.mount / ".background.tiff")).stdout
        self.assertIn("pixelWidth: 560", dimensions)
        self.assertIn("pixelHeight: 308", dimensions)

    def test_layout_drift_is_rejected(self):
        mutations = (
            (".", "bwsp", dict(presentation.window_settings(), WindowBounds="{{0, 0}, {900, 600}}")),
            (".", "bwsp", dict(presentation.window_settings(), ShowToolbar=True)),
            ("Faderline.app", "Iloc", (410, 162)),
            ("Applications", "Iloc", (150, 162)),
        )
        for name, key, value in mutations:
            with self.subTest(key=key, name=name):
                with DSStore.open(str(self.mount / ".DS_Store"), "r+") as store:
                    original = store[name][key]
                    store[name][key] = value
                with self.assertRaisesRegex(ValueError, "Incorrect"):
                    self.verify()
                with DSStore.open(str(self.mount / ".DS_Store"), "r+") as store:
                    store[name][key] = original
        with DSStore.open(str(self.mount / ".DS_Store"), "r+") as store:
            store["."]["icvp"] = dict(store["."]["icvp"], iconSize=48.0)
        with self.assertRaisesRegex(ValueError, "Incorrect Finder icon settings"):
            self.verify()

    def test_extra_visible_item_missing_background_and_wrong_alias_are_rejected(self):
        readme = self.mount / "README.txt"
        readme.write_text("Not part of the installer")
        with self.assertRaisesRegex(ValueError, "only Faderline.app"):
            self.verify()
        readme.unlink()
        background = self.mount / ".background.tiff"
        background.rename(self.mount / ".saved-background.tiff")
        with self.assertRaisesRegex(ValueError, "Missing background"):
            self.verify()
        background.write_bytes(b"Replacement file has a different ID")
        with self.assertRaisesRegex(ValueError, "does not reference this image"):
            self.verify()

    def test_renderer_failure_does_not_create_metadata(self):
        (self.mount / ".DS_Store").unlink()
        with patch.object(presentation.subprocess, "run",
                          side_effect=subprocess.CalledProcessError(1, ["swift"])):
            with self.assertRaises(subprocess.CalledProcessError):
                presentation.write_presentation(self.mount, "unsigned-development")
        self.assertFalse((self.mount / ".DS_Store").exists())

    def test_unsigned_label_cannot_be_silently_removed(self):
        with self.assertRaisesRegex(ValueError, "unsigned-development volume labeling"):
            presentation.verify_presentation(self.mount, "developer-id-notarized", self.volume)


@unittest.skipUnless(sys.platform == "darwin", "Requires AppKit background rendering")
class BackgroundRenderingTests(unittest.TestCase):
    def test_retina_background_has_only_arrow_and_optional_development_warning(self):
        inspect = """
            import AppKit
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let reps = NSBitmapImageRep.imageReps(with: data).compactMap { $0 as? NSBitmapImageRep }
            guard let image = reps.first else { fatalError("Missing TIFF representation") }
            let base = image.colorAt(x: 0, y: 0)!
            func changedPixels(_ rows: Range<Int>) -> Int {
                var count = 0
                for y in rows {
                    for x in 0..<image.pixelsWide {
                        if image.colorAt(x: x, y: y)! != base { count += 1 }
                    }
                }
                return count
            }
            let result: [String: Any] = [
                "sizes": reps.map { [$0.pixelsWide, $0.pixelsHigh] },
                "header": changedPixels(0..<100),
                "arrow": changedPixels(140..<185),
                "footer": changedPixels(225..<308)
            ]
            let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(data: json, encoding: .utf8)!)
        """
        with tempfile.TemporaryDirectory() as temporary:
            for mode in ("developer-id-notarized", "unsigned-development"):
                with self.subTest(mode=mode):
                    background = str(Path(temporary) / f"{mode}.tiff")
                    rendered = subprocess.run(
                        ["swift", str(ROOT / "scripts/dmg-background.swift"), background, mode],
                        capture_output=True, text=True,
                    )
                    self.assertEqual(rendered.returncode, 0, rendered.stderr)
                    result = subprocess.run(
                        ["swift", "-e", textwrap.dedent(inspect), background],
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    pixels = json.loads(result.stdout)
                    self.assertEqual(pixels["sizes"], [[560, 308], [1120, 616]])
                    self.assertGreater(pixels["arrow"], 0)
                    self.assertEqual(pixels["footer"], 0, "No instructions or platform footnote")
                    if mode == "developer-id-notarized":
                        self.assertEqual(pixels["header"], 0, "Public background must have no text")
                    else:
                        self.assertGreater(pixels["header"], 0, "Development notice must be visible")
        source = (ROOT / "scripts/dmg-background.swift").read_text()
        self.assertIn('text("UNSIGNED DEVELOPMENT"', source)
        self.assertIn('text("Not Developer ID signed or notarized"', source)
        self.assertNotIn("Drag Faderline", source)
        self.assertNotIn("To update", source)
        self.assertNotIn("macOS 15+", source)


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS packaging tools")
class SignedPathMockTests(unittest.TestCase):
    def test_signed_flow_keeps_layout_and_signs_only_the_final_image(self):
        # Real disk images, metadata, checksums and ad-hoc app signature; mocked
        # Developer ID / Apple services only. No credentials or uploads are used.
        with tempfile.TemporaryDirectory() as temporary:
            tools = Path(temporary)
            identity = "Developer ID Application: Mock"
            calls = tools / "calls.jsonl"
            stubs = {
                "security": f"print('1) mock \"{identity}\"')",
                "xcrun": """
                    if '--find' in args:
                        print('/mock/apple-tool')
                    elif 'submit' in args:
                        plistlib.dump({'status': 'Accepted', 'id': 'mock-only'},
                                      sys.stdout.buffer)
                    elif 'history' in args or 'stapler' in args:
                        pass
                    else:
                        raise SystemExit('Unexpected Apple invocation')
                """,
                "spctl": "pass",
                "xcodebuild": """
                    derived = Path(args[args.index('-derivedDataPath') + 1])
                    app = derived / 'Build/Products/Release/Faderline.app/Contents'
                    (app / 'MacOS').mkdir(parents=True)
                    subprocess.run(['clang', '-arch', 'arm64', '-x', 'c', '-',
                                    '-o', str(app / 'MacOS/Faderline')],
                                   input=b'int main(void) { return 0; }', check=True)
                    settings = dict(arg.split('=', 1) for arg in args if '=' in arg)
                    with (app / 'Info.plist').open('wb') as output:
                        plistlib.dump({
                            'CFBundleShortVersionString': settings['MARKETING_VERSION'],
                            'CFBundleVersion': settings['CURRENT_PROJECT_VERSION'],
                            'CFBundleIdentifier': 'com.faderline.app',
                            'CFBundleExecutable': 'Faderline',
                            'CFBundlePackageType': 'APPL',
                            'LSMinimumSystemVersion': '15.0',
                            'NSMicrophoneUsageDescription': 'Test permission',
                        }, output)
                """,
                "codesign": f"""
                    if '--display' in args and '--entitlements' not in args:
                        print('Authority={identity}', file=sys.stderr)
                    elif '--sign' in args and args[-1].endswith('.dmg'):
                        pass
                    elif '--verify' in args and args[-1].endswith('.dmg'):
                        pass
                    else:
                        if '--sign' in args:
                            args[args.index('--sign') + 1] = '-'
                            args = ['--timestamp=none' if arg == '--timestamp' else arg
                                    for arg in args]
                        subprocess.run(['/usr/bin/codesign', *args], check=True)
                """,
                "hdiutil": "subprocess.run(['/usr/bin/hdiutil', *args], check=True)",
            }
            for name, body in stubs.items():
                tool = tools / name
                tool.write_text(
                    f"#!{sys.executable}\nimport sys, plistlib, subprocess, json\n"
                    "from pathlib import Path\nargs = sys.argv[1:]\n"
                    f"with open({str(calls)!r}, 'a') as log:\n"
                    f"    log.write(json.dumps([{name!r}, *args]) + '\\n')\n"
                    + textwrap.dedent(body).strip() + "\n"
                )
                tool.chmod(0o755)
            result = subprocess.run(
                ["bash", str(SCRIPT), "--version", "1.2.3", "--build-number", "42",
                 "--developer-id", identity, "--notary-profile", "mock-only",
                 "--output", str(tools / "output")],
                env=dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                         PACKAGING_PYTHON=sys.executable),
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Verified Finder layout: 560x340, 96px icons", result.stdout)
            output = tools / "output/Faderline-1.2.3-arm64-developer-id-notarized"
            self.assertEqual(
                {item.name for item in output.iterdir()},
                {"Faderline.app", "Faderline-1.2.3-arm64-developer-id-notarized.dmg",
                 "Faderline-1.2.3-arm64-developer-id-notarized.sha256"},
            )
            commands = [json.loads(line) for line in calls.read_text().splitlines()]
            converted = next(i for i, cmd in enumerate(commands)
                             if cmd[:2] == ["hdiutil", "convert"])
            signed = next(i for i, cmd in enumerate(commands)
                          if cmd[0] == "codesign" and "--sign" in cmd
                          and cmd[-1].endswith(".dmg"))
            self.assertLess(converted, signed)
            submissions = [cmd for cmd in commands if cmd[:3] == ["xcrun", "notarytool", "submit"]]
            self.assertEqual(len(submissions), 2)
            self.assertTrue(submissions[0][3].endswith(".zip"))
            self.assertTrue(submissions[1][3].endswith(".dmg"))
            self.assertEqual(len([cmd for cmd in commands
                                  if cmd[:3] == ["xcrun", "stapler", "staple"]]), 2)
            self.assertEqual(len([cmd for cmd in commands if cmd[0] == "spctl"]), 2)
            self.assertFalse(any(cmd[0] == "codesign" and "--sign" in cmd
                                 and cmd[cmd.index("--sign") + 1] == "-" for cmd in commands))
            self.assertNotIn("UNSIGNED DEVELOPMENT", result.stdout)


if __name__ == "__main__":
    unittest.main()
