# AudioMixer

A native ARM64 macOS audio mixer — a modern replacement for [LadioCast](https://apps.apple.com/us/app/ladiocast/id411213048), which is Intel-only and will break when Rosetta 2 is removed.

## Features

- **2 input channels** (expandable by design) — select any audio input device and specific L/R channels
- **1 main output** (expandable by design) — route mixed audio to any output device
- **Per-input volume** with +6 dB boost toggle
- **Real-time VU meters** on inputs and output
- **Device hot-plug** — automatically detects connect/disconnect
- **Persistent configuration** — remembers device selections and volumes across launches
- **Drift-compensated resampling** — handles 44.1 ↔ 48 kHz conversion and long-run clock drift without clicks

## Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon (ARM64)
- Microphone permission (prompted on first launch)

## Building

### Swift Package Manager

```bash
swift build
swift run AudioMixer
```

### Xcode

Open `AudioMixer.xcodeproj`, select the AudioMixer scheme, press ⌘R.

> Full Xcode required (not just Command Line Tools).

## Architecture

```
Sources/AudioMixer/
├── AudioMixerApp.swift            # App entry + microphone permission request
├── Models/                        # Data models (Codable persistence)
├── Audio/
│   ├── ChannelRingBuffer.swift    # Lock-free SPSC ring buffer (atomics, real-time safe)
│   ├── DriftCompensatingReader.swift  # Servo-tuned resampler (handles clock drift)
│   ├── HALAudioUnits.swift        # Raw AUHAL input/output unit wrappers
│   ├── HALMixerEngine.swift       # Active mixing engine (LadioCast-style AUHAL path)
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

This replaces an earlier AVAudioEngine approach that produced crackling due to independent clock domains. The AUHAL engine mirrors the architecture of LadioCast (AUGraph + circular buffers + explicit render callbacks).

## Technology

| Layer | Technology |
|---|---|
| UI | SwiftUI (macOS 15+) |
| Audio engine | CoreAudio AUHAL (raw AudioUnit, no AVAudioEngine) |
| Device enumeration | CoreAudio HAL (AudioObjectGetPropertyData) |
| Mixing | vDSP (Accelerate framework) |
| Architecture | MVVM with @Observable |
| Persistence | UserDefaults + Codable JSON |

## For AI agents

Use [`agents.md`](agents.md) as the **canonical, tool-agnostic** guide for all AI agents (Copilot, Claude, Cursor, and custom agents).

If your agent supports provider-specific instruction files (for example, `.github/copilot-instructions.md`), those files should only point back to `agents.md` instead of duplicating guidance.

## License

MIT
