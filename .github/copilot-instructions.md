# Copilot Instructions — AudioMixer

> **Read `agents.md` first** for the full agent guide. This file is a concise
> quick-reference for GitHub Copilot inline suggestions and PR reviews.

## What this project is

Native ARM64 macOS audio mixer. SSL 2 USB audio interface → AUHAL mixing engine
→ BlackHole / MacBook speakers. **Not** sandboxed, **not** streaming, single user.

## Build commands

```bash
swift build                   # primary — always verify after changes
swift test                    # 13 XCTest tests (ring buffer + resampler)
xcodebuild -project AudioMixer.xcodeproj -scheme AudioMixer -configuration Debug build
```

Both SPM and Xcode must build. When you add a `.swift` file, update `project.pbxproj`
too (PBXFileReference + PBXBuildFile + group membership + Sources build phase).

## Active engine

`HALMixerEngine` (AUHAL-based). The `typealias ActiveMixerEngine = HALMixerEngine`
in `MixerViewModel.swift` is the single switch point. `LegacyMixerEngine` (AVAudioEngine)
is kept for A/B comparison — **do not delete it yet**.

## Real-time safety — CRITICAL

The AUHAL input callback (`halInputCallback`) and output render callback
(`HALMixerEngine.mix`) run on real-time threads. Inside them, **never**:

- Allocate memory (`Array(...)`, `String(...)`, `.append`, etc.)
- Take a lock (`os_unfair_lock`, `NSLock`, `DispatchQueue.sync`)
- Call ObjC/Swift runtime (`print`, dynamic dispatch, `AnyObject` boxing)
- Block (`sleep`, file I/O, network)

Use `Atomic<T>` (acquire/release) for all shared state crossing the RT boundary.

## Engine lifecycle rules

- **`engine.start()` must NOT run on the main thread.** It calls
  `AudioComponentInstanceNew` which makes a synchronous Mach IPC call to
  coreaudiod — whose reply must be delivered on the main run loop. Calling
  `start()` on the main thread deadlocks. It runs in `Task.detached` in
  `MixerViewModel.rebuildEngine()` — keep it there.

- **Always stop the engine cleanly before exit.** `AudioComponentInstanceDispose`
  tells coreaudiod to release IOProc registrations. Skipping this (SIGKILL)
  leaves orphaned HAL state that blocks the next launch. The `willTerminateNotification`
  handler in `AudioMixerApp` handles this.

## Colors and theme

All UI colors are defined in `Sources/AudioMixer/Views/MixerTheme.swift` using
`NSColor` semantic system colors for light/dark adaptability. **Do not add
hardcoded `Color(red:green:blue:)` or `Color(white:)` values elsewhere.**

## Logging

Runtime logs use `os_log` (`Logger`, subsystem `"com.audiomixer"`). To read them:

```bash
log show --predicate 'subsystem == "com.audiomixer"' --info --last 30s
log stream --predicate 'subsystem == "com.audiomixer"' --level info
```

## Deployment target

macOS 15.0 — required for `Synchronization.Atomic`. Do not lower it.
Swift language mode 5 — intentional (Swift 6 strict concurrency conflicts with
legitimate AUHAL callback patterns).
