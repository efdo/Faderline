import SwiftUI

/// Central color palette for the AudioMixer UI.
/// Uses NSColor semantic system colors so all backgrounds and text adapt
/// automatically to light and dark mode.
enum MixerTheme {
    // MARK: - Backgrounds (system-adaptive)
    /// Main window background — follows system appearance
    static let windowBg     = Color(NSColor.windowBackgroundColor)
    /// Strip panel background — slightly raised surface
    static let stripBg      = Color(NSColor.controlBackgroundColor)
    /// VU meter track — visible in both appearances
    static let meterTrackBg = Color(NSColor.separatorColor)

    // MARK: - Text (system-adaptive)
    static let textPrimary    = Color(NSColor.labelColor)
    static let textLabel      = Color(NSColor.secondaryLabelColor)
    static let textMeterLabel = Color(NSColor.tertiaryLabelColor)
    static let textSecondary  = Color(NSColor.tertiaryLabelColor)

    // MARK: - Route buttons
    /// Active "Main" routing — green, legible in both appearances
    static let routeActiveMain = Color(red: 0.18, green: 0.60, blue: 0.27)
    /// Inactive route button fill — system control surface
    static let routeInactive   = Color(NSColor.controlColor)
    /// Foreground on active (colored-background) buttons
    static let routeActiveFg   = Color.white
    /// Foreground on inactive (system-surface) buttons
    static let routeInactiveFg = Color(NSColor.controlTextColor)
    /// Disabled aux placeholder foreground
    static let routeDisabledFg = Color(NSColor.disabledControlTextColor)

    // MARK: - +6 dB boost button
    static let boostActive   = Color(red: 0.85, green: 0.47, blue: 0.10)  // amber
    static let boostInactive = Color(NSColor.controlColor)

    // MARK: - Engine status / alerts
    static let engineRunning = Color(red: 0.22, green: 0.80, blue: 0.35)
    static let engineStopped = Color(NSColor.disabledControlTextColor)
    static let errorBannerBg = Color(red: 0.55, green: 0.08, blue: 0.08)
}
