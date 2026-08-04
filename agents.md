# AudioMixer — Agent Guide

This document is the first thing an AI agent should read before making changes to this project. It covers the architecture, real-time constraints, known history, gotchas, and workflows.

---

## What this project is

A native ARM64 macOS audio mixer (LadioCast replacement) built with Swift/SwiftUI. Core use case: SSL 2 USB audio interface (stereo input, 2 channels) → mix → its own **AudioMixer Virtual Microphone** (for Teams/Zoom/any conferencing app) and/or MacBook speakers/BlackHole for local monitoring.

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

# Virtual mic driver + its CFPlugIn-loaded property/IO tests (Xcode-only,
# not part of Package.swift — see "Virtual microphone" section below)
xcodebuild -project AudioMixer.xcodeproj -target AudioMixerVirtualDriverTests -configuration Debug build
./build/Debug/AudioMixerVirtualDriverTests ./build/Debug/AudioMixerVirtualDriver.driver
```

**Always run all of these after any non-trivial change.** The Xcode project and SPM package are both maintained; they must both build. The driver test run doesn't install anything system-wide, so it's safe to run anytime.

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
│   ├── VirtualDriverManager.swift # Install/update/remove lifecycle for the virtual mic driver
│   └── LevelMeter.swift           # Unused tap helper (legacy, safe to ignore)
├── ViewModels/
│   ├── MixerViewModel.swift       # Top-level coordinator; owns engine + device manager
│   ├── InputStripViewModel.swift
│   └── OutputStripViewModel.swift
└── Views/
    ├── MixerTheme.swift           # Central color palette — change colors here only
    ├── MixerWindow.swift          # Main 2-column layout + error banner + engine status
    ├── InputStripView.swift       # Device picker, channel selectors, volume, routing
    ├── OutputStripView.swift      # Monitor device picker, monitoring toggle, L/R meters
    ├── VirtualMicPanelView.swift  # Virtual mic driver state + install/remove + meters
    └── VUMeterView.swift          # Animated horizontal level bar

Driver/                            # Xcode-only targets; not part of Package.swift
├── AudioMixerVirtualDriver.c       # AudioServerPlugIn HAL bundle — the virtual microphone
├── Info.plist                     # CFPlugIn factory/type declarations for the driver
├── AudioMixerVirtualDriverTests/main.c  # CFPlugIn-loaded property/IO smoke tests
└── Packaging/
    ├── build_installer_pkgs.sh    # Builds install/uninstall .pkg (see below)
    ├── scripts_install/postinstall
    └── scripts_uninstall/postinstall

Tests/
├── AudioMixerTests/AudioMixerTests.swift      # 17 standalone tests (run via swift script)
└── AudioMixerEngineTests/EngineTests.swift    # 21 XCTest tests for ring buffer + resampler + engine routing + config migration
```

---

## Virtual microphone (AudioMixerVirtualDriver)

AudioMixer can feed its mixed bus directly into Teams, Zoom, or any other
Core Audio client as a microphone — no BlackHole or other third-party
loopback driver required. This works via a clean-room `AudioServerPlugIn`
HAL plug-in, `AudioMixerVirtualDriver.driver`, implemented directly against
Apple's public `<CoreAudio/AudioServerPlugIn.h>` interface (see
`Driver/AudioMixerVirtualDriver.c`). It exposes one fixed stereo, 48kHz,
Float32 duplex device named **AudioMixer Virtual Microphone**: AudioMixer
writes the mix to its output side via a normal AUHAL output unit; Teams/
Zoom read the same frames back from its input side via a normal AUHAL
input unit.

### Output routing

`HALMixerEngine.OutputConfig` carries two independent slots:
- `virtualDeviceID` — the virtual mic device, always the **primary** output
  (the mix clock) when present.
- `monitorDeviceID` — an optional **secondary**, independently clocked
  hardware output for local listening, fed from the post-mix bus via its
  own `ChannelRingBuffer` + `DriftCompensatingReader`.

If the driver isn't installed, `monitorDeviceID` becomes the primary output
directly — this is the hardware-only fallback, functionally identical to
pre-virtual-mic behavior. `HALMixerEngine.resolveOutputRouting(_:)` is the
pure function that resolves this and is unit tested without touching real
Core Audio devices.

Both the input-strip and monitor-output device pickers filter out the
virtual mic's own UID (`MixerViewModel.selectableInputDevices` /
`selectableMonitorDevices`) so it can never be routed back into itself.

### Install/update/remove lifecycle

`VirtualDriverManager` never performs privileged filesystem operations
itself. It opens a signed `.pkg` with `NSWorkspace`, which hands off to
**Installer.app** — that's what shows the administrator authorization
prompt and does the actual root-owned copy/remove +
`launchctl kickstart -k system/com.apple.audio.coreaudiod` (see
`Driver/Packaging/scripts_install/postinstall` and `scripts_uninstall/postinstall`).
`MixerViewModel.installOrUpdateVirtualDriver()` / `.removeVirtualDriver()`
stop the engine first, then await `VirtualDriverManager.waitForDevicePresence(expectPresent:)`
before rebuilding — this polls Core Audio's device list (with a bounded
timeout) rather than assuming a fixed restart delay.

### Building and testing the driver locally

```bash
# Build the .driver bundle + property/IO smoke tests, run them via CFPlugIn
# (does NOT install anything into /Library/Audio/Plug-Ins/HAL):
xcodebuild -project AudioMixer.xcodeproj -target AudioMixerVirtualDriverTests -configuration Debug build
./build/Debug/AudioMixerVirtualDriverTests ./build/Debug/AudioMixerVirtualDriver.driver

# Build the install/uninstall .pkg for manual local testing (unsigned unless
# PKG_SIGNING_IDENTITY is set — see the script header for all env vars):
Driver/Packaging/build_installer_pkgs.sh
```

Installing/removing the driver restarts coreaudiod, which briefly
interrupts all system audio — this is why it's always an explicit,
user-initiated action (Install/Update/Remove buttons in `VirtualMicPanelView`),
never automatic.

---

## Active audio engine: HALMixerEngine

**Do not modify the signal path without understanding real-time constraints** (see below).

### Signal flow

```
SSL 2 (48kHz, 2ch)
  → HALInputUnit (AUHAL, input-only)
      input callback: AudioUnitRender → ChannelRingBuffer (all hw channels)
  → DriftCompensatingReader.pull()    ← called from primary output render thread
      linear-interp resampling + servo ratio (handles clock drift + 44.1↔48k)
  → HALMixerEngine.mix()             ← primary output render callback (the mix clock)
      per-strip: channel map (L/R index select) → vDSP_vsma (volume+accumulate)
      → vDSP_vclip (soft-limit ±1) → RMS metering (atomic writes)
      → (if monitoring) copy post-mix bus into a ChannelRingBuffer
  → HALOutputUnit (AUHAL, output-only) — primary
      → AudioMixer Virtual Microphone (if installed) or MacBook speakers/BlackHole (fallback)

  (in parallel, only when monitoring a hardware device while the virtual mic is primary)
  → DriftCompensatingReader.pull()    ← called from monitor's own output render thread
      resamples the post-mix ring at the monitor device's independent rate
  → HALOutputUnit (AUHAL, output-only) — secondary/monitor
      → MacBook speakers / BlackHole 2ch / any selected hardware device
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
monitor: fill=2048 ratio=1.000000 underruns=0 overruns=0 starved=0
```
- `callbacks=0` → AUHAL input not firing (permission denied or wrong device)
- `callbacks>0, underruns>0` → ring buffer draining (drift or quantum mismatch)
- `starved>0` → resampler couldn't get enough input frames (underrun on reader side)
- `fill≫targetFill(2048)` → producer faster than consumer, servo should correct
- `monitor:` line only appears when hardware monitoring is active alongside the virtual mic

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
3. Select a monitor output (BlackHole or MacBook speakers). Audio should be audible.
4. Toggle +6dB boost on/off — immediate volume change, no glitch.
5. Hot-unplug SSL 2 — app should handle gracefully (error banner or re-enumerate).
6. **10-minute soak** — sustained audio with no clicks, pops, or crackling.
7. Check `[AudioMixer diagnostics]` in console: `underruns` and `starved` should stay at 0 or near-zero over the soak.

### Virtual microphone validation (also for the user, not the agent)

Requires an administrator password (Installer.app's authorization prompt)
and real conferencing apps — not something the agent can complete:

1. In the **Virtual Microphone** panel, click **Install**. Approve the
   administrator prompt in Installer.app. The status dot should turn green
   and read "Installed (v1.0)" once coreaudiod finishes restarting.
2. Open Teams (or Zoom) → audio device settings → select **AudioMixer
   Virtual Microphone** as the input device. Speak into the SSL 2 with the
   mixer running: the other party (or a test recording) should hear the
   mixed input.
3. With the virtual mic selected in Teams/Zoom, also enable **Monitoring**
   with a hardware device (e.g. MacBook speakers) selected in the app —
   confirm you hear the same audio locally with no audible drift or
   glitching relative to what the conferencing app receives, and that the
   `monitor:` diagnostics line stays at low/zero underruns over a few
   minutes.
4. Disable Monitoring — local playback should stop while the virtual mic
   feed (as heard by Teams/Zoom) is unaffected.
5. Click **Remove** in the Virtual Microphone panel, approve the prompt —
   the device should disappear from Teams/Zoom's device list, and the app
   should fall back to hardware-only output using the monitor device
   directly.

---

## What's left to do

- **Hardware validation** (blocked: requires user at machine — see protocol above)
- **Virtual microphone validation** (blocked: requires administrator password + Teams/Zoom — see protocol above)
- **Signing/notarization for distribution** — `Driver/Packaging/build_installer_pkgs.sh` produces unsigned packages by default; a public release needs `PKG_SIGNING_IDENTITY`/`CODE_SIGN_IDENTITY_DRIVER` (Developer ID Installer / Developer ID Application certificates) plus `xcrun notarytool submit` + `xcrun stapler staple`, none of which are configured in this repo
- After hardware validation: delete `LegacyMixerEngine.swift` and `LevelMeter.swift`
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
