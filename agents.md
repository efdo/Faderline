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

---

## Known gotchas (hard-won — read before touching the engine)

### 1. Never SIGKILL AudioMixer while the engine is running

Using `kill -9 <pid>` or `pkill -9 AudioMixer` skips Swift's `deinit` and
AppKit's `applicationWillTerminate`. CoreAudio's HAL (`coreaudiod`) never
receives `AudioComponentInstanceDispose` / `AudioOutputUnitStop` for our
AUHAL units, so it accumulates **orphaned IOProc registrations** for the SSL 2
(or any other USB device).

On the next launch, `AudioComponentInstanceNew` tries to register a new IOProc
for the same device. CoreaudioD accepts the Mach IPC message but **never
replies** — the calling thread blocks forever on `mach_msg2_trap`.

**Fix already in place:** `AudioMixerApp` listens for
`NSApplication.willTerminateNotification` and calls `MixerViewModel.stopEngine()`
before exit. AppKit routes `SIGTERM` (the default `kill <pid>`) through
`applicationWillTerminate`, so a normal kill is safe.

**If you see the engine hang on launch:** coreaudiod has orphaned state. Run:
```bash
sudo launchctl stop com.apple.audio.coreaudiod
```
Wait ~3 s for coreaudiod to restart, then relaunch the app.

---

### 2. Engine start must NOT run on the main thread

`AudioComponentInstanceNew` (inside `HALInputUnit.init`) makes a synchronous
Mach IPC call to coreaudiod. CoreaudioD's reply must be dispatched on the **main
run loop**. If `start()` is called from the main thread (e.g. directly in
`AudioMixerApp.init` → `MixerViewModel.init`), the main run loop is busy and
the reply can never be delivered → infinite deadlock.

**Fix already in place:** `MixerViewModel.rebuildEngine()` runs
`engine.start()` inside `Task.detached(priority: .userInitiated)` so the main
thread stays free to pump coreaudiod's reply.

**Do not move `start()` back to the main thread.** The `DispatchQueue.main.async`
wrapper in `init` only defers to the next run-loop cycle — it still runs on the
main thread and will deadlock if coreaudiod is slow.

---

### 3. SSL 2 is simultaneously the system default output device and our capture input

The SSL 2 (device ID 206 at time of writing) is typically set as macOS's
**default output device** by the user for headphone monitoring. Our AUHAL input
unit also captures from it.

This means coreaudiod has to manage the device in two HAL contexts at once.
Consequences:
- HAL lock contention is higher than with a capture-only device.
- The 'nope' error (`0x6E6F7065 / 1852797029`) may appear in the system log
  from HAL proxy operations — this is **non-fatal** and comes from the system's
  output path, not our code.
- When running diagnostics, `HALC_ShellObject::SetPropertyData failed` messages
  are expected noise; focus on our subsystem logs (`subsystem == "com.audiomixer"`).

---

### 4. Diagnostics are `.info` level — use `--info` flag with `log show`

All runtime log messages use `logger.info(...)` or higher. The `log show`
default only shows `.default` and above, which omits `.info`. Always use:

```bash
log show --predicate 'subsystem == "com.audiomixer"' --info --last 30s
```

Or for live streaming while the app is open:
```bash
log stream --predicate 'subsystem == "com.audiomixer"' --level info
```

Without `--info`, you will see **zero log lines** and assume the engine is silent.

---

### 5. Both VU meter and level polling work; bars may appear frozen at first

The VU meter applies a **3× sensitivity multiplier** in `VUMeterView` before
display. Raw RMS levels from a quiet room / noise floor are typically `0.001–0.01`
(−60 to −40 dBFS), which after ×3 still look near-zero. The bars should move
visibly when speaking into or playing audio through the SSL 2.

If bars show 0 after engine start, check the diagnostics log first:
- `callbacks=0` → AUHAL input callback is not firing (microphone permission denied, or wrong device selected)
- `callbacks>0, fill≈2048, underruns=0` → engine is healthy; signal may genuinely be silent
- `starved>0` → resampler underrun; ring buffer not filling fast enough
