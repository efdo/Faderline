import SwiftUI

/// Central color palette for the AudioMixer UI.
/// All values are calibrated for legibility on macOS dark-mode displays.
enum MixerTheme {
    // MARK: - Backgrounds
    /// Main window background: deep charcoal
    static let windowBg = Color(white: 0.10)
    /// Strip panel background: slightly raised from window
    static let stripBg = Color(white: 0.17)
    /// VU meter track background
    static let meterTrackBg = Color(white: 0.09)

    // MARK: - Text
    /// Primary readable text (device names, values)
    static let textPrimary = Color(white: 0.88)
    /// Section / strip header labels
    static let textLabel = Color(white: 0.56)
    /// Meter channel labels (L / R)
    static let textMeterLabel = Color(white: 0.50)
    /// Status / secondary info
    static let textSecondary = Color(white: 0.46)

    // MARK: - Route buttons
    /// Active "Main" routing — green (routed = good)
    static let routeActiveMain = Color(red: 0.20, green: 0.62, blue: 0.29)
    /// Inactive / disabled route button background
    static let routeInactive = Color(white: 0.24)
    /// Foreground on both active and inactive route buttons
    static let routeFg = Color(white: 0.90)
    /// Disabled aux button foreground
    static let routeDisabledFg = Color(white: 0.38)

    // MARK: - +6 dB boost button
    static let boostActive = Color(red: 0.85, green: 0.47, blue: 0.10)   // amber
    static let boostInactive = Color(white: 0.24)

    // MARK: - Engine status
    static let engineRunning = Color(red: 0.22, green: 0.80, blue: 0.35)
    static let engineStopped = Color(white: 0.32)
    static let errorBannerBg = Color(red: 0.50, green: 0.08, blue: 0.08)
}
