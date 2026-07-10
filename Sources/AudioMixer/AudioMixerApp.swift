import SwiftUI
import AVFoundation

@main
struct AudioMixerApp: App {
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
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 700, height: 500)
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
