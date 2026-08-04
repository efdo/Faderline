import Foundation
import AppKit
import CoreAudio
import OSLog

private let logger = Logger(subsystem: "com.audiomixer", category: "VirtualDriverManager")

/// Coordinates installing, updating, and removing the AudioMixer virtual
/// microphone HAL plug-in (`AudioMixerVirtualDriver.driver`), and reports
/// whether the resulting Core Audio device is currently present.
///
/// This class never performs privileged filesystem operations itself. It
/// only launches a signed `.pkg` with `NSWorkspace`, which hands off to
/// Installer.app — that is what shows the administrator authorization
/// prompt and performs the root-owned copy/remove + coreaudiod restart
/// (see `Driver/Packaging/scripts_install/postinstall` and
/// `scripts_uninstall/postinstall`).
@Observable
final class VirtualDriverManager {
    /// Must match the identifier embedded in `Driver/Info.plist`.
    static let bundleIdentifier = "com.audiomixer.virtualdriver"
    /// Must match `CopyDeviceUID()` in `AudioMixerVirtualDriver.c`.
    static let virtualDeviceUID = "com.audiomixer.virtualmic.device"
    /// Fixed system install location for HAL plug-ins.
    static let installedDriverPath = "/Library/Audio/Plug-Ins/HAL/AudioMixerVirtualDriver.driver"

    enum State: Equatable {
        case notInstalled
        case installed(version: String)
        case updateAvailable(installedVersion: String, availableVersion: String)
        case installing
        case removing
        case error(String)
    }

    private(set) var state: State = .notInstalled
    /// The live Core Audio device ID for the virtual mic, if it is
    /// currently enumerated by the system (nil while not installed, while
    /// coreaudiod is mid-restart, or right after install/remove before the
    /// device list has caught up).
    private(set) var virtualDeviceID: AudioDeviceID?

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refreshState()
        installHotPlugListener()
    }

    deinit {
        removeHotPlugListener()
    }

    // MARK: - State refresh

    /// Re-reads the installed driver bundle's version (if any) and the
    /// current Core Audio device list. Safe to call from the main thread at
    /// any time; does no privileged I/O.
    func refreshState() {
        virtualDeviceID = Self.findVirtualDeviceID()

        guard let installedVersion = Self.installedBundleVersion() else {
            if case .installing = state { return }  // avoid flicker mid-install
            state = .notInstalled
            return
        }

        if let bundledVersion = Self.bundledInstallerVersion(), bundledVersion != installedVersion,
           Self.isVersion(bundledVersion, newerThan: installedVersion) {
            state = .updateAvailable(installedVersion: installedVersion, availableVersion: bundledVersion)
        } else {
            state = .installed(version: installedVersion)
        }
    }

    private static func installedBundleVersion() -> String? {
        guard FileManager.default.fileExists(atPath: installedDriverPath) else { return nil }
        let infoPlistPath = installedDriverPath + "/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: infoPlistPath) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// The version of the driver embedded in this app build's installer
    /// package, if one is bundled. Distribution builds embed
    /// `AudioMixerVirtualDriverInstaller.pkg` (built by
    /// `Driver/Packaging/build_installer_pkgs.sh`) as an app resource and a
    /// sibling `AudioMixerVirtualDriverVersion.txt` recording its version,
    /// since a `.pkg`'s version isn't cheap to introspect at runtime.
    private static func bundledInstallerVersion() -> String? {
        guard let url = Bundle.main.url(forResource: "AudioMixerVirtualDriverVersion", withExtension: "txt") else {
            return nil
        }
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lhsParts.count, rhsParts.count) {
            let l = i < lhsParts.count ? lhsParts[i] : 0
            let r = i < rhsParts.count ? rhsParts[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Install / Update / Remove

    /// Locates the embedded installer package for this app build. Returns
    /// nil in local `swift build`/`swift run` development, where no
    /// installer package resource is embedded — the driver must be
    /// installed manually via `Driver/Packaging/build_installer_pkgs.sh`
    /// during development.
    private static func embeddedPackageURL(resourceName: String) -> URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "pkg")
    }

    /// Opens the install/update package with Installer.app. Installer.app
    /// itself prompts the user for administrator authorization; this call
    /// never elevates privileges directly. Returns false if no installer
    /// package is embedded in this build.
    @discardableResult
    func beginInstallOrUpdate() -> Bool {
        guard let url = Self.embeddedPackageURL(resourceName: "AudioMixerVirtualDriverInstaller") else {
            logger.error("No embedded installer package found in app bundle")
            state = .error("This build does not include the virtual microphone installer.")
            return false
        }
        state = .installing
        logger.info("Opening virtual driver installer package")
        NSWorkspace.shared.open(url)
        return true
    }

    /// Opens the removal package with Installer.app. Same authorization
    /// model as `beginInstallOrUpdate()`.
    @discardableResult
    func beginRemoval() -> Bool {
        guard let url = Self.embeddedPackageURL(resourceName: "AudioMixerVirtualDriverUninstaller") else {
            logger.error("No embedded uninstaller package found in app bundle")
            state = .error("This build does not include the virtual microphone uninstaller.")
            return false
        }
        state = .removing
        logger.info("Opening virtual driver uninstaller package")
        NSWorkspace.shared.open(url)
        return true
    }

    /// Polls (via the Core Audio device-list property listener) until the
    /// virtual device's presence matches `expectPresent`, or `timeout`
    /// elapses. Intended to be awaited after `beginInstallOrUpdate()` /
    /// `beginRemoval()` so the caller can rebuild the mixer engine once
    /// coreaudiod has finished restarting and republished its device list.
    /// Always calls `refreshState()` before returning.
    @MainActor
    func waitForDevicePresence(expectPresent: Bool, timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            refreshState()
            let present = virtualDeviceID != nil
            if present == expectPresent { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        refreshState()
        return (virtualDeviceID != nil) == expectPresent
    }

    // MARK: - Core Audio device lookup

    private static func findVirtualDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr
        else { return nil }

        for deviceID in deviceIDs where uid(of: deviceID) == virtualDeviceUID {
            return deviceID
        }
        return nil
    }

    private static func uid(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return nil }
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr,
              let cfString = value?.takeRetainedValue()
        else { return nil }
        return cfString as String
    }

    // MARK: - Hot-plug listener (device list changes, e.g. after coreaudiod restart)

    private func installHotPlugListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshState() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    private func removeHotPlugListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }
}
