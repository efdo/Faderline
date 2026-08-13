import SwiftUI
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AudioMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var mixerViewModel = MixerViewModel()
    @State private var micPermissionDenied = false

    var body: some Scene {
        WindowGroup("Mixer") {
            MixerWindow()
                .environment(mixerViewModel)
                .alert("Microphone Access Denied", isPresented: $micPermissionDenied) {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("AudioMixer needs microphone access to capture audio. Enable it in System Settings → Privacy & Security → Microphone.")
                }
                .task { await requestMicrophonePermission() }
                // Ensure AUHAL units are properly disposed on termination so
                // coreaudiod releases IOProc registrations for the SSL 2 (or any
                // other device). Without this, `kill`ing the process leaves
                // orphaned HAL state that blocks the next launch.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification)) { _ in
                    mixerViewModel.stopEngine()
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 580)
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
