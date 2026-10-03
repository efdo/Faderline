# Faderline

A native ARM64 macOS audio mixer built with SwiftUI and CoreAudio for low-latency local routing and monitoring.

## Features

- **2-channel input mixing** (expandable by design) — select any audio input device and map specific hardware channels to the mixer
- **Configurable main output** — route the mixed signal to any available output device
- **dB-calibrated faders** — per-input and master level control from silence up to +6 dB
- **Pan, mute, and solo** — shape and isolate sources without rebuilding the engine
- **Real-time metering** — input/output RMS meters with peak-hold and clip indication
- **Device hot-plug** — detects audio device connect/disconnect events
- **Persistent configuration** — remembers device selections and mix settings across launches
- **Drift-compensated resampling** — handles 44.1 ↔ 48 kHz conversion and long-run clock drift without clicks

## Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon (ARM64)
- Microphone permission (prompted on first launch)

## Building

### Swift Package Manager

```bash
swift build
swift run Faderline
```

### Xcode

Open `Faderline.xcodeproj`, select the Faderline scheme, press ⌘R.

> Full Xcode required (not just Command Line Tools).

CI and releases use the stable GitHub-hosted **macos-26 / Xcode 26.6**
environment and **macOS 26.5 SDK**, while preserving **macOS 15.0+ / arm64**
deployment. See the [build environment policy](docs/RELEASING.md#ci-build-environment)
for exact toolchain pins, verification, and hosted availability limits.

### App icon

The Xcode app bundle (including release installers) uses
`Resources/Assets.xcassets/AppIcon.appiconset`. It contains all macOS icon
sizes at 1x and 2x, generated from the 1024×1024
`icon_512x512@2x.png` source with transparent 5% outer padding on each edge.
Replace the PNGs in this set to update the icon,
keeping the filenames and dimensions listed in `Contents.json`.
SPM builds a standalone executable, not an `.app` bundle, so it does not
package the app icon.

## Architecture

```
Sources/Faderline/
├── FaderlineApp.swift            # App entry + microphone permission request
├── Models/                        # Data models (Codable persistence)
├── Audio/
│   ├── ChannelRingBuffer.swift    # Lock-free SPSC ring buffer (atomics, real-time safe)
│   ├── DriftCompensatingReader.swift  # Servo-tuned resampler (handles clock drift)
│   ├── HALAudioUnits.swift        # Raw AUHAL input/output unit wrappers
│   ├── HALMixerEngine.swift       # Active AUHAL-based mixing engine
│   └── DeviceManager.swift        # CoreAudio HAL device enumeration + hot-plug
├── ViewModels/                    # MVVM (@Observable)
└── Views/                         # SwiftUI — all colors in MixerTheme.swift
```

### Signal path

```
Input device (e.g. SSL 2)
  → AUHAL input unit (explicit render callback)
  → ChannelRingBuffer (lock-free, all hardware channels)
  → DriftCompensatingReader (linear-interp resampler, servo-tuned ratio)
  → vDSP mix (channel map → volume → accumulate)
  → AUHAL output unit
  → Output device (BlackHole / speakers)
```

This replaces an earlier AVAudioEngine approach that produced crackling due to independent clock domains. The active engine uses AUHAL with explicit render callbacks, circular buffering, and drift-compensated reading to keep capture and output synchronized.

## Technology

| Layer | Technology |
|---|---|
| UI | SwiftUI (macOS 15+) |
| Audio engine | CoreAudio AUHAL (raw AudioUnit, no AVAudioEngine) |
| Device enumeration | CoreAudio HAL (AudioObjectGetPropertyData) |
| Mixing | vDSP (Accelerate framework) |
| Architecture | MVVM with @Observable |
| Persistence | UserDefaults + Codable JSON |

## Releasing

Build an app-only Release DMG locally:

```bash
bash scripts/package-app.sh --version 1.2.3 --unsigned-development
```

Publishing a GitHub Release triggers
[`.github/workflows/release.yml`](.github/workflows/release.yml), which attaches
the DMG and SHA-256 checksum to that release. By default these are explicitly
labeled **unsigned development prereleases**, not signed public releases.
Developer ID signing and notarization require configured credentials and never
fall back to unsigned output.

Packages contain **Faderline.app** for **macOS 15+ / Apple Silicon**, an
Applications shortcut, and installation information only; no virtual microphone
driver is included or managed. Install by dragging the app to Applications.
For manual updates, **quit Faderline cleanly with Command-Q and wait for exit**
before replacing the app. There is no automatic updater.
See [`docs/RELEASING.md`](docs/RELEASING.md) for versioning, packaging, signing,
installation, and release instructions.

## For AI agents

Use [`agents.md`](agents.md) as the **canonical, tool-agnostic** guide for all AI agents (Copilot, Claude, Cursor, and custom agents).

If your agent supports provider-specific instruction files (for example, `.github/copilot-instructions.md`), those files should only point back to `agents.md` instead of duplicating guidance.

## Contributing

Contributions are welcome, but this project is still tuned around real hardware validation on macOS. Start with the build and test commands above, read [`agents.md`](agents.md) for repository-specific constraints, and expect manual audio-device testing to remain important for changes near the engine or device-management path.

## License

Licensed under the MIT License. See [`LICENSE`](LICENSE).
