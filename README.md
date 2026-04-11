# AudioMixer

A native ARM64 macOS audio mixer app — a modern replacement for the core functionality of LadioCast.

## Features

- **2 input channels** (expandable by design) — select any audio input device and specific L/R channels
- **1 main output** (expandable by design) — route mixed audio to any output device
- **Per-input volume control** with +6 dB boost toggle
- **Real-time VU meters** on inputs and output
- **Device hot-plug** — automatically detects when devices are connected/disconnected
- **Persistent configuration** — remembers your device selections and volumes across launches
- **Dark mixer UI** matching the LadioCast aesthetic

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (ARM64)

## Building

### With Swift Package Manager (Command Line)

```bash
cd AudioMixer
swift build
swift run AudioMixer
```

### With Xcode

Open `AudioMixer/AudioMixer.xcodeproj` in Xcode, select the AudioMixer scheme, and build/run (⌘R).

> **Note:** The Xcode project requires full Xcode (not just Command Line Tools).

## Architecture

```
Sources/AudioMixer/
├── AudioMixerApp.swift          # SwiftUI app entry point
├── Models/                      # Data models
│   ├── AudioDevice.swift        # CoreAudio device wrapper
│   ├── AudioChannel.swift       # Channel descriptor
│   └── MixerConfiguration.swift # Persisted settings (Codable)
├── Audio/                       # Audio engine layer
│   ├── DeviceManager.swift      # CoreAudio HAL device enumeration + hot-plug
│   ├── MixerEngine.swift        # AVAudioEngine mixing graph
│   └── LevelMeter.swift         # Audio level tap helper
├── ViewModels/                  # MVVM view models (@Observable)
│   ├── MixerViewModel.swift     # Top-level coordinator
│   ├── InputStripViewModel.swift
│   └── OutputStripViewModel.swift
└── Views/                       # SwiftUI views
    ├── MixerWindow.swift        # Main 2-column layout
    ├── InputStripView.swift     # Input strip with all controls
    ├── OutputStripView.swift    # Output strip with meters
    └── VUMeterView.swift        # Animated level bar
```

## Technology

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI (macOS 14+) |
| Audio mixing | AVAudioEngine + AVAudioMixerNode |
| Device enumeration | CoreAudio HAL (AudioObjectGetPropertyData) |
| Architecture | MVVM with @Observable |
| Persistence | UserDefaults + Codable |

## License

MIT
