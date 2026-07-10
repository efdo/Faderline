# AudioMixer — Agent Guide

This document is the first thing an AI agent should read before making changes to this project. It covers the architecture, real-time constraints, known history, gotchas, and workflows.

---

## What this project is

A native ARM64 macOS audio mixer (LadioCast replacement) built with Swift/SwiftUI. Core use case: SSL 2 USB audio interface (stereo input, 2 channels) → mix → BlackHole 2ch or MacBook speakers.

- **Not** a streaming app. No Icecast/SHOUTcast.
- **Not** sandboxed — no App Store target.
- **Target users:** 1 person, daily driver.

---

## Build & Test

```bash
# Build (SPM — works without Xcode open)
swift build

# Run standalone legacy tests (no XCTest, just swift script)
swift Tests/AudioMixerTests/AudioMixerTests.swift

# Run SPM test target (real XCTest, covers engine internals)
swift test

# Full Xcode build (needed to check pbxproj consistency)
xcodebuild -project AudioMixer.xcodeproj -scheme AudioMixer -configuration Debug build
```

**Always run all three verification steps after any non-trivial change.** The Xcode project and SPM package are both maintained; they must both build.

---

## Project layout

```
Sources/AudioMixer/
├── AudioMixerApp.swift            # @main SwiftUI entry point; requests mic permission
├── Models/
│   ├── AudioDevice.swift          # CoreAudio device ID + metadata wrapper
│   ├── AudioChannel.swift         # Channel descriptor (index, label)
│   └── MixerConfiguration.swift   # Codable persistence (UserDefaults JSON)
├── Audio/
│   ├── ChannelRingBuffer.swift    # Lock-free SPSC N-channel planar ring buffer (atomics)
│   ├── DriftCompensatingReader.swift  # Linear-interp resampler + servo drift correction
│   ├── HALAudioUnits.swift        # HALInputUnit + HALOutputUnit (raw AUHAL wrappers)
│   ├── HALMixerEngine.swift       # ★ Active engine — AUHAL-based, LadioCast-style
│   ├── LegacyMixerEngine.swift    # AVAudioEngine-based engine (kept for A/B, do NOT delete yet)
│   ├── DeviceManager.swift        # CoreAudio HAL device enumeration + hot-plug
│   └── LevelMeter.swift           # Unused tap helper (legacy, safe to ignore)
├── ViewModels/
│   ├── MixerViewModel.swift       # Top-level coordinator; owns engine + device manager
│   ├── InputStripViewModel.swift
│   └── OutputStripViewModel.swift
└── Views/
    ├── MixerTheme.swift           # Central color palette — change colors here only
    ├── MixerWindow.swift          # Main 2-column layout + error banner + engine status
    ├── InputStripView.swift       # Device picker, channel selectors, volume, routing
    ├── OutputStripView.swift      # Device picker + L/R level meters
    └── VUMeterView.swift          # Animated horizontal level bar

Tests/
├── AudioMixerTests/AudioMixerTests.swift      # 15 standalone tests (run via swift script)
└── AudioMixerEngineTests/EngineTests.swift    # 13 XCTest tests for ring buffer + resampler
```

---

## Active audio engine: HALMixerEngine

**Do not modify the signal path without understanding real-time constraints** (see below).

### Signal flow

```
SSL 2 (48kHz, 2ch)
  → HALInputUnit (AUHAL, input-only)
      input callback: AudioUnitRender → ChannelRingBuffer (all hw channels)
  → DriftCompensatingReader.pull()    ← called from output render thread
      linear-interp resampling + servo ratio (handles clock drift + 44.1↔48k)
  → HALMixerEngine.mix()             ← output render callback
      per-strip: channel map (L/R index select) → vDSP_vsma (volume+accumulate)
      → vDSP_vclip (soft-limit ±1) → RMS metering (atomic writes)
  → HALOutputUnit (AUHAL, output-only)
      → MacBook speakers / BlackHole 2ch
```

### Engine switching (A/B)

`MixerViewModel.swift` has a one-line typealias:
```swift
typealias ActiveMixerEngine = HALMixerEngine   // swap to LegacyMixerEngine to A/B
```

### Engine public API (both engines share this shape)

```swift
func start(inputs: [InputConfig], output: OutputConfig) throws
func stop()
func setVolume(_ volume: Float, forInput index: Int)   // atomic, no rebuild
func setRouteToMain(_ enabled: Bool, forInput index: Int)  // atomic, no rebuild
var inputLevels: [Int: (left: Float, right: Float)]    // polled at 30Hz
var outputLevel: (left: Float, right: Float)]
var isRunning: Bool
var lastError: String?
var diagnostics: String   // callbacks/fill/ratio/underruns — check this first when debugging
```

### Diagnostics

Every 3 seconds while running, the Xcode console prints:
```
[AudioMixer diagnostics]
dev0: callbacks=144 fill=2048 ratio=1.000000 underruns=0 overruns=0 starved=0
```
- `callbacks=0` → AUHAL input not firing (permission denied or wrong device)
- `callbacks>0, underruns>0` → ring buffer draining (drift or quantum mismatch)
- `starved>0` → resampler couldn't get enough input frames (underrun on reader side)
- `fill≫targetFill(2048)` → producer faster than consumer, servo should correct

---

## Real-time safety rules

**Never violate these in the input callback (`halInputCallback`) or output render callback (`halOutputRenderCallback` / `HALMixerEngine.mix`):**

1. **No allocation** — no `Array(...)`, no `String(...)`, no `[T].append`, no closures that capture heap objects (unless they were pre-allocated and the closure itself was pre-allocated).
2. **No locks** — no `os_unfair_lock`, no `NSLock`, no `DispatchQueue.sync`. Use `Atomic` with acquire/release.
3. **No ObjC/Swift runtime** — no `print`, no dynamic dispatch through protocols on unconfirmed-Sendable types, no `AnyObject` boxing.
4. **No blocking syscalls** — no file I/O, no network, no `sleep`.
5. `ChannelRingBuffer` and `DriftCompensatingReader` are RT-safe by design. Keep them that way.

`HALMixerEngine.mix` is `static` specifically so it captures no `self` — only `RenderState` (a `final class` whose inner atomics are RT-safe).

---

## Xcode project maintenance

The Xcode project (`AudioMixer.xcodeproj/project.pbxproj`) is maintained **in addition to** `Package.swift`. When you add a new `.swift` file, you must add it to both:

1. **SPM** — SPM discovers files automatically by path; just place the file.
2. **Xcode pbxproj** — requires two entries each: a `PBXFileReference` and a `PBXBuildFile`, plus membership in the correct group and the `Sources` build phase. Use the Python script pattern from the commit history, or add via Xcode UI and commit the change.

If Xcode says "cannot find X in scope" but `swift build` succeeds, the pbxproj is missing the file reference.

---

## Known history & decisions

| Decision | Rationale |
|---|---|
| AUHAL over AVAudioEngine | AVAudioEngine with multiple independent instances caused clock drift → crackling. AUHAL gives explicit control over the render thread. |
| DriftCompensatingReader (servo resampler) | Without drift compensation, long-running sessions drain/overflow the ring buffer → clicks. Servo holds fill at ~50% target. |
| LegacyMixerEngine kept | Kept for A/B hardware comparison. Delete only after sustained click-free hardware testing (10+ min soak). |
| Swift language mode v5 | Swift 6 strict concurrency trips on the AUHAL callback patterns (legitimate unsafe audio thread use). v5 is intentional, not debt. |
| No sandbox | Sandboxing `com.apple.security.device.audio-input` was removed in an earlier session to debug issues. The app uses TCC privacy permissions instead. |
| Deployment target macOS 15 | Required for `Synchronization.Atomic` (used in ring buffer and strip parameter slots). |
| `NSMicrophoneUsageDescription` in Info.plist | macOS 14+ TCC blocks AUHAL input silently without this. The app requests access at launch via `AVCaptureDevice.requestAccess`. |

---

## Hardware test protocol (for the user, not the agent)

Before removing `LegacyMixerEngine`:

1. Launch app, verify green "Engine Running" dot.
2. SSL 2 Input 1 → L=Ch1, R=Ch2, volume 70%, Main routed. VU meters should move when speaking.
3. Select output (BlackHole or MacBook speakers). Audio should be audible.
4. Toggle +6dB boost on/off — immediate volume change, no glitch.
5. Hot-unplug SSL 2 — app should handle gracefully (error banner or re-enumerate).
6. **10-minute soak** — sustained audio with no clicks, pops, or crackling.
7. Check `[AudioMixer diagnostics]` in console: `underruns` and `starved` should stay at 0 or near-zero over the soak.

---

## What's left to do

- **Hardware validation** (blocked: requires user at machine — see protocol above)
- After validation: delete `LegacyMixerEngine.swift` and `LevelMeter.swift`
- Optional future work: hot-unplug graceful recovery, sample-rate-change listener, Aux outputs
