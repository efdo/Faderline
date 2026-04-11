import SwiftUI

@main
struct AudioMixerApp: App {
    @State private var mixerViewModel = MixerViewModel()

    var body: some Scene {
        WindowGroup("Mixer") {
            MixerWindow()
                .environment(mixerViewModel)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 700, height: 500)
    }
}
