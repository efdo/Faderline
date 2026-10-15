import SwiftUI
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var mixerViewModel: MixerViewModel?
    private var isShuttingDown = false

    /// Upper bound on waiting for engine cleanup, in case coreaudiod hangs.
    private static let shutdownTimeout: TimeInterval = 5

    private var sigtermSource: DispatchSourceSignal?

    /// AppKit does not route SIGTERM through termination on its own; the
    /// default action kills the process and skips engine cleanup. Convert it
    /// into a normal `terminate(_:)` so `kill <pid>` disposes AUHAL units.
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Hop off the GCD main-queue block: terminating from inside it would
        // block the main queue that the shutdown reply is delivered on.
        source.setEventHandler { RunLoop.main.perform { NSApp.terminate(nil) } }
        source.resume()
        sigtermSource = source
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Defers termination until AUHAL units are disposed so coreaudiod releases
    /// IOProc registrations (see agents.md gotcha #1). SIGTERM is routed
    /// here too (see above). Never blocks main: CoreAudio startup needs the main run loop.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let mixerViewModel else { return .terminateNow }
        // A shutdown is already pending; it will terminate when it finishes.
        guard !isShuttingDown else { return .terminateCancel }
        isShuttingDown = true

        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        mixerViewModel.shutdownEngine(completion: reply)
        let timeout = Timer(timeInterval: Self.shutdownTimeout, repeats: false) { _ in reply() }
        RunLoop.main.add(timeout, forMode: .common)
        return .terminateLater
    }
}

@main
struct FaderlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var mixerViewModel = MixerViewModel()
    @State private var micPermissionDenied = false

    var body: some Scene {
        let consoleSize = MixerTheme.Metrics.consoleMinimumSize(inputCount: mixerViewModel.inputStrips.count)

        WindowGroup("Faderline", id: "mixer") {
            MixerWindow()
                .environment(mixerViewModel)
                .alert("Microphone Access Denied", isPresented: $micPermissionDenied) {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Faderline needs microphone access to capture audio. Enable it in System Settings → Privacy & Security → Microphone.")
                }
                .task { await requestMicrophonePermission() }
                .onAppear { appDelegate.mixerViewModel = mixerViewModel }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: consoleSize.width, height: consoleSize.height)
    }

    private func requestMicrophonePermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { micPermissionDenied = true }
        default:
            micPermissionDenied = true
        }
    }
}
