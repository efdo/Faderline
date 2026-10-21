# Faderline

[![Latest release (including prereleases)](https://img.shields.io/github/v/release/efdo/Faderline?include_prereleases&sort=semver&color=brightgreen)](https://github.com/efdo/Faderline/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Bring your audio inputs together in one small mixer for your Mac. Choose where
the sound comes from, adjust the mix, and send it to an output device you
already use.

![Faderline 0.0.3 with two input strips and a main output strip. Meter levels vary with the signal and device.](docs/assets/mixer-overview-v0.0.3.png)

**[Download Faderline](https://github.com/efdo/Faderline/releases)**
 · **[Getting started](docs/GETTING_STARTED.md)**

Requires **macOS 15 (Sequoia) or later, Apple Silicon, and microphone permission**.
Download `Faderline-<version>.dmg` from the release's **Assets**, open it, and
drag **Faderline.app** to **Applications**. No build tools needed.

## Make it your mix

- Mix two input strips into one main output.
- Choose an input device and its mono channel or stereo pair.
- Adjust input and output levels with faders, from silence to +6 dB.
- Pan, mute, or solo your sources.
- Watch level meters, held peaks, and clip indicators.
- Keep your device selections and mix settings between launches.
- Recall named profiles without losing your working adjustments.

Faderline uses audio devices already available on your Mac. It does not
automatically capture every app's sound, stream to online services, or include
or manage a virtual microphone driver.

The [getting-started guide](docs/GETTING_STARTED.md) walks through a safe first
setup, explains the controls, and covers
[common problems](docs/GETTING_STARTED.md#if-something-is-missing-or-silent).
[Updates are manual](docs/GETTING_STARTED.md#update-faderline): quit normally
with Command-Q and wait for exit before replacing the app.

## Profiles

The **Profiles** menu in the macOS menu bar lets you keep different setups for
calls, recording, or listening. There is no profile UI in the mixer window; the
window title shows the selected profile (for example "Faderline — Calls").

**Default** is not a profile: it is your everyday mix, saved automatically just
like before, and it never shows as edited. Your existing mix becomes Default on
upgrade. Press Command-0 for Default and Command-1 through Command-9 for the
first nine profiles.

Use **Save As…** (Shift-Command-S) to create a profile from your current mix;
on Default, **Save Profile…** (Command-S) does the same. Profiles include
input/output devices, input channel mappings, pan, input/master levels, input
mute, and routing to Main. With a profile selected, **Save Profile** updates its
saved preset, and the title adds **— Edited** when the mix differs from it.

Adjustments are always recovered automatically as a separate working draft for
each profile, including after quitting. Switching restores that profile's draft
without prompting or discarding changes. **Revert to Saved…** restores its saved
preset; Revert and Delete ask before discarding data. Rename does not change the
mix. Deleting the selected profile returns to Default; "Default" is reserved and
cannot be used as a profile name.

Solo clears when switching or reverting, while an engaged master mute stays
engaged. Neither is saved or restored on relaunch. Latency remains app-wide.
If a device or saved channel is unavailable, the affected input stays inactive
(or output stops), with a quiet warning. The intended selections are preserved
and reconnect by device identity; Faderline never substitutes another device.
Switching devices or channels can briefly interrupt audio.

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
