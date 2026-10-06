import SwiftUI

/// Main mixer window: a console-style row of channel strips (inputs, then
/// the main output) aligned against a left-hand row-label gutter.
struct MixerWindow: View {
    @Environment(MixerViewModel.self) private var viewModel

    var body: some View {
        let minimumSize = MixerTheme.Metrics.consoleMinimumSize(inputCount: viewModel.inputStrips.count)

        VStack(spacing: 0) {
            // Error banner
            if let error = viewModel.mixerEngine.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Dismiss") {
                        viewModel.mixerEngine.lastError = nil
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                }
                .padding(8)
                .background(MixerTheme.errorBannerBg)
            }

            // Console: row-label gutter + one strip per input + the main output strip.
            HStack(alignment: .top, spacing: MixerTheme.Metrics.consoleSpacing) {
                ConsoleGutterView()
                ForEach(viewModel.inputStrips) { strip in
                    ConsoleStripView(kind: .input(strip))
                }
                ConsoleStripView(kind: .main(viewModel.mainOutput))
            }
            .padding(MixerTheme.Metrics.consolePadding)
            .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MixerTheme.consoleBg)
        .background(InitialWindowFocus())
    }
}

struct InitialWindowFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> InitialWindowFocusView {
        InitialWindowFocusView()
    }

    func updateNSView(_ nsView: InitialWindowFocusView, context: Context) {}
}

final class InitialWindowFocusView: NSView {
    private weak var initializedWindow: NSWindow?
    private var keyMonitor: Any?
    private var trackingMenus: Set<ObjectIdentifier> = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        trackingMenus.removeAll()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuBeganTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuEndedTracking(_:)),
            name: NSMenu.didEndTrackingNotification, object: nil
        )
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window,
                  event.window === window, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  self.trackingMenus.isEmpty, window.attachedSheet == nil, NSApp.modalWindow == nil
            else { return event }
            return window.makeFirstResponder(nil) ? nil : event
        }
        guard window !== initializedWindow else { return }
        if window.isKeyWindow {
            clearInitialFocus()
        } else {
            NotificationCenter.default.addObserver(
                self, selector: #selector(clearInitialFocus),
                name: NSWindow.didBecomeKeyNotification, object: window
            )
        }
    }

    @objc private func clearInitialFocus() {
        guard let window, window !== initializedWindow else { return }
        initializedWindow = window
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeKeyNotification, object: window
        )
        // Wait until AppKit and SwiftUI finish assigning the launch-time responder.
        DispatchQueue.main.async { [weak window] in
            window?.makeFirstResponder(nil)
        }
    }

    @objc private func menuBeganTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        trackingMenus.insert(ObjectIdentifier(menu))
    }

    @objc private func menuEndedTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        trackingMenus.remove(ObjectIdentifier(menu))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
