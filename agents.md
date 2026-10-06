# Faderline — Agent Guide

This document is the first thing an AI agent should read before making changes to this project. It is the **canonical, tool-agnostic** guide for all agents (Copilot, Claude, Cursor, custom agents). It covers architecture, real-time constraints, known history, gotchas, and workflows.

Any provider-specific instruction files in the repo should be thin pointers back
to this document and should not duplicate or diverge from it.

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
swift Tests/FaderlineTests/FaderlineTests.swift

# Run SPM test target (real XCTest, covers engine internals)
swift test

# Full Xcode build (needed to check pbxproj consistency)
xcodebuild -project Faderline.xcodeproj -scheme Faderline -configuration Debug build
```

**Always run all three verification steps after any non-trivial change.** The Xcode project and SPM package are both maintained; they must both build.
After those checks, **launch the app once** to confirm the UI/runtime path still starts.
Before every launch, stop any running Faderline (or legacy AudioMixer) instances
with `SIGTERM` using their exact PIDs, and wait for them to exit. Never use `SIGKILL`.
```bash
open /tmp/Faderline-Build/Build/Products/Debug/Faderline.app
```

---

## Project layout

```
Sources/Faderline/
├── FaderlineApp.swift            # @main SwiftUI entry point; requests mic permission
├── Models/
│   ├── AudioDevice.swift          # CoreAudio device ID + metadata wrapper
│   ├── AudioChannel.swift         # Channel descriptor (index, label)
│   └── MixerConfiguration.swift   # Codable persistence (UserDefaults JSON) + legacy migration
├── Audio/
│   ├── ChannelRingBuffer.swift    # Lock-free SPSC N-channel planar ring buffer (atomics)
│   ├── DriftCompensatingReader.swift  # Linear-interp resampler + servo drift correction
│   ├── HALAudioUnits.swift        # HALInputUnit + HALOutputUnit (raw AUHAL wrappers)
│   ├── HALMixerEngine.swift       # ★ Active engine — AUHAL-based, LadioCast-style
│   ├── LegacyMixerEngine.swift    # AVAudioEngine-based engine (kept for A/B, do NOT delete yet)
│   ├── FaderTaper.swift           # Pure dB↔position↔gain math + pan law — no UI import, unit-tested
│   ├── DeviceManager.swift        # CoreAudio HAL device enumeration + hot-plug
│   └── LevelMeter.swift           # Unused tap helper (legacy, safe to ignore)
├── ViewModels/
│   ├── MixerViewModel.swift       # Top-level coordinator; owns engine + device manager
│   ├── InputStripViewModel.swift
│   └── OutputStripViewModel.swift
└── Views/
    ├── MixerTheme.swift           # Central color palette + MixerTheme.Metrics + ConsoleGutterView/ConsoleRow
    ├── MixerWindow.swift          # Console layout: gutter + one ConsoleStripView per strip
    ├── ConsoleStripView.swift     # One channel strip (input or main flavor) + ConsoleScaleView
    ├── FaderView.swift            # Vertical dB-calibrated fader (drag / shift-drag / double-click)
    ├── PanKnobView.swift          # Circular pan/balance knob
    └── ChannelMeterView.swift     # Vertical stereo meter: peak-hold marker + clip latch

Tests/
├── FaderlineTests/FaderlineTests.swift      # ~21 standalone tests (run via swift script)
└── FaderlineEngineTests/EngineTests.swift    # ~39 XCTest tests: ring buffer, resampler, fader taper, config migration
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
      per-strip: channel map (L/R index select) → pan (pre-resolved L/R gains)
      → vDSP_vsma (volume+accumulate, gated by route/mute/solo-in-place)
      → pre-fader RMS + peak metering (atomic writes)
      → master gain/mute → peak (pre-limiter) → vDSP_vclip (soft-limit ±1)
      → post-limiter RMS metering
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
func setPan(_ pan: Float, forInput index: Int)             // atomic; panGains resolved off the render thread
func setMute(_ muted: Bool, forInput index: Int)           // atomic, no rebuild
func setSolo(_ soloed: Bool, forInput index: Int)          // atomic; recomputes anySolo across all strips
func setOutputVolume(_ gain: Float)                        // atomic master gain, no rebuild
func setOutputMuted(_ muted: Bool)                         // atomic master mute, no rebuild
var inputLevels: [Int: (left: Float, right: Float)]    // polled at 30Hz, pre-fader RMS
var inputPeaks: [Int: (left: Float, right: Float)]     // drained via exchange(0, ...) at 30Hz
var outputLevel: (left: Float, right: Float)]          // post-limiter RMS
var outputPeak: (left: Float, right: Float)            // pre-limiter peak; >= 1.0 means a genuine over
var isRunning: Bool
var lastError: String?
var diagnostics: String   // callbacks/fill/ratio/underruns/mute/solo/pan/peak — check this first when debugging
```

`InputConfig` carries `pan`/`mute`/`solo` in addition to the original
`volume`/`routeToMain`; `OutputConfig` carries the master `volume` (linear
gain from the fader taper). Gain values passed as `volume` are **linear
gain from `FaderTaper.gain(forDB:)`**, not the old 0...1 slider value.

### Diagnostics

Every 3 seconds while running, the Xcode console prints:
```
[Faderline diagnostics]
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

Pan is the one addition that could easily leak `cos`/`sin` into the render
thread — don't let it. `setPan(_:forInput:)` resolves `FaderTaper.panGains(_:)`
on the calling (UI) thread and stores the two resulting floats (`panL`/`panR`)
as atomics; `mix()` only ever does a relaxed load and a multiply.

Peak metering is a plain (non-atomic-RMW) load-compare-store running max on
the render thread, drained via `Atomic.exchange(0, ...)` on the UI thread at
~30 Hz. This is deliberately racy: worst case the UI misses one render
quantum's peak sample. That's an acceptable trade for staying lock-free —
don't "fix" it into a compare-and-swap loop.

---

## Console UI architecture

The mixer window (`MixerWindow.swift`) is a Logic Pro–style console: a row of
vertical channel strips (one `ConsoleStripView` per input, plus one for the
main output) aligned against a left-hand row-label gutter
(`ConsoleGutterView`), not the old horizontal LadioCast-style cards.

- **Window sizing:** `MixerTheme.Metrics.consoleMinimumSize(inputCount:)`
  derives the minimum console size from the strip count, row heights, spacing,
  and padding. The default window size uses those same metrics to fit the
  content without extra empty space. The stable `mixer` scene ID avoids reusing
  older oversized window frames; subsequent user resizing is still restored.
  The window uses `.contentMinSize` so it can grow but cannot shrink below the
  console. Engine status and low-latency controls are hidden
  from the UI; their internal state and support remain intact.
- **`ConsoleRow`** (in `MixerTheme.swift`) is the single source of truth for
  row order, labels, and heights (Device, Channels, Output, Pan, dB,
  fader+meter, Mute/Solo, name plate). Both `ConsoleGutterView` and
  `ConsoleStripView` iterate `ConsoleRow.allCases` — **keep them in sync** if
  you add/remove/reorder a row, or the gutter labels will drift from the
  strip controls.
- **`FaderTaper.swift`** (in `Audio/`, not `Views/` — it's pure math, no UI
  import, and unit-tested directly) is the single source of truth for
  dB↔position↔gain and the pan law. `FaderView`, `ConsoleScaleView` (inside
  `ConsoleStripView.swift`), and `ChannelMeterView` all read positions through
  it, which is why the fader's travel, the shared tick column, and the
  meter's fill always agree visually.
- **There is no `+6 dB` boost button anymore.** The fader spans −∞…+6 dB
  (unity detent at 80% of travel); `InputStripViewModel`/`OutputStripViewModel`
  expose `gainDB` as the source of truth, plus computed `gain`/`faderPosition`.
- **Solo and master mute are intentionally not persisted** in
  `MixerConfiguration` — relaunching into a soloed or silent mix would be a
  footgun. Strip mute *is* persisted (it's a real mix decision, e.g. "input 2
  is unused").
- **`ConsoleStripKind`** (`.input`/`.main`) drives which rows a strip shows;
  the main strip has no Channels/Output/Pan/Solo (rendered as em-dash
  placeholders) since it represents the physical output device, not a routed
  source.
- **Pan knobs:** 36-point diameter with L/R markers, a drag-only center snap
  within +/-0.08 pan, and double-click to recenter. The snap is UI-side only;
  persisted pan values and the engine's pan law are unchanged.
- **Device/channel selectors:** `ConsolePicker` wraps a native `NSPopUpButton`
  with standard keyboard navigation and focus rings. `InitialWindowFocus` clears
  automatic focus only when each window first opens; subsequent keyboard focus
  remains visible and is preserved when switching back to the app. Both rows
  fill the same strip width and show the full selected label in a hover tooltip;
  dB fields also expose their current text on hover. Escape clears control focus
  (after dismissing an open selector menu); Tab resumes normal focus navigation.
  Pan tooltips show Center or a left/right percentage. Mute/Solo tooltips show
  the current state and describe the click action.

---

## Xcode project maintenance

The Xcode project (`Faderline.xcodeproj/project.pbxproj`) is maintained **in addition to** `Package.swift`. When you add a new `.swift` file, you must add it to both:

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
| Console-style UI (Logic Pro–like strips) | Replaced the horizontal LadioCast-style cards. Added dB-calibrated fader (`FaderTaper`), pan/balance, mute, solo, and peak/clip metering — the `+6dB` button was retired since the fader's range subsumes it. |
| Pan law: constant-power with 0 dB center | A traditional -3 dB center pan law would have changed every existing strip's level on upgrade. Center must be a no-op; the trade-off is up to +3 dB extra headroom at hard pan, made visible via the clip indicator. |

---

## Hardware test protocol (for the user, not the agent)

Before removing `LegacyMixerEngine`:

1. Launch app, verify the engine starts using the diagnostics log (the engine
   status indicator is currently hidden from the UI).
2. SSL 2 Input 1 → L=Ch1, R=Ch2, fader at 0 dB, Main routed. Meters should move when speaking.
3. Select output (BlackHole or MacBook speakers). Audio should be audible.
4. Drag the fader through its full range, including past 0 dB toward +6 dB — smooth, no glitch. Type an exact dB value into the field and press Return.
5. Pan hard left/right on a strip with the same input on L and R — audio should move fully to one side.
6. Mute and Solo each strip — Solo should silence all other non-soloed strips; Mute should only silence that strip.
7. Drive a strip hot enough to clip — the clip LED above its meter should latch; click it to reset.
8. Hot-unplug SSL 2 — app should handle gracefully (error banner or re-enumerate).
9. **10-minute soak** — sustained audio with no clicks, pops, or crackling.
10. Check `[Faderline diagnostics]` in console: `underruns` and `starved` should stay at 0 or near-zero over the soak.

---

## What's left to do

- **Hardware validation** (blocked: requires user at machine — see protocol above). Re-run the full soak after the console UI change even if it passed before: `mix()` gained pan/mute/solo/peak logic on the render path.
- After validation: delete `LegacyMixerEngine.swift` and `LevelMeter.swift`
- Optional future work: hot-unplug graceful recovery, sample-rate-change listener, Aux outputs

---

## Known gotchas (hard-won — read before touching the engine)

### 1. Never SIGKILL Faderline while the engine is running

Using `kill -9 <pid>` or `pkill -9 Faderline` skips Swift's `deinit` and
AppKit's `applicationWillTerminate`. CoreAudio's HAL (`coreaudiod`) never
receives `AudioComponentInstanceDispose` / `AudioOutputUnitStop` for our
AUHAL units, so it accumulates **orphaned IOProc registrations** for the SSL 2
(or any other USB device).

On the next launch, `AudioComponentInstanceNew` tries to register a new IOProc
for the same device. CoreaudioD accepts the Mach IPC message but **never
replies** — the calling thread blocks forever on `mach_msg2_trap`.

**Fix already in place:** `FaderlineApp` listens for
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
`FaderlineApp.init` → `MixerViewModel.init`), the main run loop is busy and
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
  are expected noise; focus on our subsystem logs (`subsystem == "com.faderline"`).

---

### 4. Diagnostics are `.info` level — use `--info` flag with `log show`

All runtime log messages use `logger.info(...)` or higher. The `log show`
default only shows `.default` and above, which omits `.info`. Always use:

```bash
log show --predicate 'subsystem == "com.faderline"' --info --last 30s
```

Or for live streaming while the app is open:
```bash
log stream --predicate 'subsystem == "com.faderline"' --level info
```

Without `--info`, you will see **zero log lines** and assume the engine is silent.

---

### 5. The meter's dB scale is shared with the fader — levels near the noise floor will look empty, not frozen

`ChannelMeterView` positions its fill through the same `FaderTaper.position(forDB:)`
mapping as `FaderView`, so the meter's visual scale matches the fader's: unity
(0 dB) sits at 80% of the track, and anything below the fader's -60 dB floor
reads as empty. Raw RMS levels from a quiet room / noise floor are typically
`0.001–0.01` linear (-60 to -40 dBFS) — genuinely near the bottom of the
scale, not a display bug. The bars should move visibly and rise toward the
green/amber boundary (-12 dB) when speaking into or playing audio through the
SSL 2. (There is no artificial sensitivity multiplier anymore — the old
`VUMeterView`'s `×3` hack and the engine's `×2` on stored RMS were both
removed when the meter switched to dB-scale positioning.)

If bars show 0 after engine start, check the diagnostics log first:
- `callbacks=0` → AUHAL input callback is not firing (microphone permission denied, or wrong device selected)
- `callbacks>0, fill≈2048, underruns=0` → engine is healthy; signal may genuinely be silent
- `starved>0` → resampler underrun; ring buffer not filling fast enough

### 6. Peak-hold on the meter is a UI-side illusion, not an engine feature

`HALMixerEngine.inputPeaks`/`outputPeak` only ever report "the peak magnitude
since the last ~33 ms poll" — far too brief to read visually, and by design
(see the real-time safety notes above on why the render thread can't do more
than a running max). The **hold** (steady for ~1.2 s) and **decay** (~20 dB/s
falloff) are implemented entirely in `ChannelMeterView`'s private `PeakHold`,
purely as a function of elapsed wall-clock time via `TimelineView`. If a peak
marker looks like it's not decaying, check `ChannelMeterView`, not the engine.
