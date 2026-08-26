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

## For AI agents

Use [`agents.md`](agents.md) as the **canonical, tool-agnostic** guide for all AI agents (Copilot, Claude, Cursor, and custom agents).

If your agent supports provider-specific instruction files (for example, `.github/copilot-instructions.md`), those files should only point back to `agents.md` instead of duplicating guidance.

## Contributing

Contributions are welcome, but this project is still tuned around real hardware validation on macOS. Start with the build and test commands above, read [`agents.md`](agents.md) for repository-specific constraints, and expect manual audio-device testing to remain important for changes near the engine or device-management path.

## License

Licensed under the MIT License. See [`LICENSE`](LICENSE).
