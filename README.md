# Faderline

Bring your audio inputs together in one small mixer for your Mac. Choose where
the sound comes from, adjust the mix, and send it to an output device you
already use.

![Faderline 0.0.3 with two input strips and a main output strip. Meter levels vary with the signal and device.](docs/assets/mixer-overview-v0.0.3.png)

**[Download the signed v0.0.3 prerelease](https://github.com/efdo/AudioMixer/releases/tag/v0.0.3)**
 · **[Getting started](docs/GETTING_STARTED.md)**
 · [All releases](https://github.com/efdo/AudioMixer/releases)

Requires **macOS 15 (Sequoia) or later, Apple Silicon, and microphone permission**.
Open the signed release's `.dmg` and drag **Faderline.app** to **Applications**.
The v0.0.3 prerelease uses the original longer asset name; new releases use
`Faderline-<version>.dmg`, with signing status stated in the release notes.
No build tools needed.

## Make it your mix

- Mix two input strips into one main output.
- Choose an input device and its mono channel or stereo pair.
- Adjust input and output levels with faders, from silence to +6 dB.
- Pan, mute, or solo your sources.
- Watch level meters, held peaks, and clip indicators.
- Keep your device selections and mix settings between launches.

Faderline uses audio devices already available on your Mac. It does not
automatically capture every app's sound, stream to online services, or include
or manage a virtual microphone driver.

The [getting-started guide](docs/GETTING_STARTED.md) walks through a safe first
setup, explains the controls, and covers
[common problems](docs/GETTING_STARTED.md#if-something-is-missing-or-silent).
[Updates are manual](docs/GETTING_STARTED.md#update-faderline): quit normally
with Command-Q and wait for exit before replacing the app.

## Building from source

The sections below are for developers. To use the app, start with the download above.

### Swift Package Manager

```bash
swift build
swift run Faderline
```

### Xcode

Open `Faderline.xcodeproj`, select the Faderline scheme, press ⌘R.

> Full Xcode required (not just Command Line Tools).

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
Input device
  → AUHAL input unit (explicit render callback)
  → ChannelRingBuffer (lock-free, all hardware channels)
  → DriftCompensatingReader (linear-interp resampler, servo-tuned ratio)
  → vDSP mix (channel map → volume → accumulate)
  → AUHAL output unit
  → Output device
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

Maintainers: see [the release guide](docs/RELEASING.md) for versioning,
app-only DMG packaging, signing, and publishing. Unsigned development packages
are labeled separately and are not the recommended download for users.

## For AI agents

Use [`agents.md`](agents.md) as the **canonical, tool-agnostic** guide for all AI agents (Copilot, Claude, Cursor, and custom agents).

If your agent supports provider-specific instruction files (for example, `.github/copilot-instructions.md`), those files should only point back to `agents.md` instead of duplicating guidance.

## Contributing

Contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for build
and pull request guidance, and [`agents.md`](agents.md) for detailed project
architecture and real-time audio constraints. Changes to audio behavior also
need validation on real hardware.

## License

Licensed under the MIT License. See [`LICENSE`](LICENSE).
