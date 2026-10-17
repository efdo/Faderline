# Contributing to Faderline

Thanks for your interest in improving Faderline. Small, focused fixes and clear
bug reports are welcome.

## Before you start

For a larger change, open an issue first to discuss the problem and proposed
approach. Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md)
to include what you expected, what happened, the macOS/Faderline versions,
steps to reproduce, and your input/output device setup. Remove private device
names or other personal details from screenshots and logs before sharing them.

## Build and check your changes

Faderline targets macOS 15 or later and Apple Silicon. Building the Xcode
project requires full Xcode, not only the Command Line Tools. From the
repository root, the project provides these checks:

```bash
swift build
swift Tests/FaderlineTests/FaderlineTests.swift
swift test
xcodebuild -project Faderline.xcodeproj -scheme Faderline -configuration Debug build
```

The Xcode project and Swift Package Manager build are both maintained. Run
checks relevant to your change; for a non-trivial change, run the full set
above. After those checks, launch the app once to confirm the UI/runtime path
starts. Before launching, stop any running Faderline or legacy AudioMixer
instances with `SIGTERM` using their exact PIDs and wait for them to exit
normally. Never use `SIGKILL`.

Debug builds use the bundle ID `com.faderline.app.debug`, so they keep their
own microphone permission and saved mix separate from an installed release.
To keep that permission across rebuilds, copy
`Config/DebugLocal.xcconfig.example` to `Config/DebugLocal.xcconfig`
(git-ignored) and set your Apple Development Team ID; otherwise Debug builds
are ad-hoc signed and macOS may ask for microphone access again.

## Changes to audio behavior

The audio callbacks have real-time constraints: avoid allocation, locks,
blocking work, and logging in the render path. Read the
[project guide](agents.md) before changing audio code; it explains these
constraints and the architecture in more detail.

Builds and automated tests cannot replace listening tests on real audio
hardware. Changes to the engine or device management need hardware validation
before they can be considered fully verified. If you can't perform it, say so
in the pull request and describe what you did verify.

## Pull requests

- Keep each pull request focused and explain the user-facing reason for the change.
- Include tests for changed behavior where practical.
- Update documentation when behavior or setup instructions change.
- Report checks you ran and any validation you could not perform.

Please avoid bundling unrelated formatting or cleanup with functional changes.
