import SwiftUI

/// Central color palette for the AudioMixer console UI.
/// Surfaces and text use NSColor semantic system colors so they adapt
/// automatically to light and dark mode. Signal colors (meter/mute/solo/clip)
/// are fixed RGB, matching professional console convention rather than
/// following the system accent color.
enum MixerTheme {
    // MARK: - Backgrounds (system-adaptive)
    /// Overall console window background.
    static let consoleBg   = Color(NSColor.windowBackgroundColor)
    /// Strip panel background — slightly raised surface.
    static let stripBg     = Color(NSColor.controlBackgroundColor)
    /// Strip background when a *different* strip is soloed.
    static let stripDimmed = Color(NSColor.controlBackgroundColor).opacity(0.5)

    // MARK: - Text (system-adaptive)
    static let textPrimary   = Color(NSColor.labelColor)
    static let textLabel     = Color(NSColor.secondaryLabelColor)
    static let textSecondary = Color(NSColor.tertiaryLabelColor)
    /// Row labels in the left-hand gutter.
    static let gutterText    = Color(NSColor.secondaryLabelColor)

    // MARK: - Fader
    static let faderTrack   = Color(NSColor.separatorColor)
    static let faderCap     = Color(NSColor.controlColor)
    static let faderCapEdge = Color(NSColor.tertiaryLabelColor)

    // MARK: - Scale ticks (shared by the fader and the meter)
    static let scaleTick = Color(NSColor.separatorColor)
    static let scaleText = Color(NSColor.tertiaryLabelColor)

    // MARK: - Meter
    static let meterBg         = Color(NSColor.separatorColor).opacity(0.4)
    static let meterLow        = Color(red: 0.20, green: 0.75, blue: 0.33)  // < -12 dB
    static let meterMid        = Color(red: 0.90, green: 0.70, blue: 0.10)  // -12...-3 dB
    static let meterHigh       = Color(red: 0.85, green: 0.20, blue: 0.15)  // > -3 dB
    static let meterPeakMarker = Color(NSColor.labelColor)

    // MARK: - Clip indicator
    static let clipOn  = Color(red: 0.90, green: 0.15, blue: 0.10)
    static let clipOff = Color(NSColor.controlColor)

    // MARK: - Mute / Solo
    static let muteOn = Color(red: 0.85, green: 0.47, blue: 0.10)  // amber
    static let soloOn = Color(red: 0.95, green: 0.80, blue: 0.15)  // yellow

    // MARK: - Pan knob
    static let knobFill      = Color(NSColor.controlColor)
    static let knobIndicator = Color(NSColor.labelColor)

    // MARK: - Output (bus) assign button — "Main"
    static let assignActive     = Color(red: 0.18, green: 0.60, blue: 0.27)  // green
    static let assignInactive   = Color(NSColor.controlColor)
    static let assignActiveFg   = Color.white
    static let assignInactiveFg = Color(NSColor.controlTextColor)

    // MARK: - Name plate (bottom color tab, Logic-style)
    static let namePlateInput = Color(red: 0.20, green: 0.45, blue: 0.75)  // blue
    static let namePlateMain  = Color(red: 0.55, green: 0.20, blue: 0.55)  // purple
    static let namePlateText  = Color.white

    // MARK: - Engine status / alerts
    static let engineRunning = Color(red: 0.22, green: 0.80, blue: 0.35)
    static let engineStopped = Color(NSColor.disabledControlTextColor)
    static let errorBannerBg = Color(red: 0.55, green: 0.08, blue: 0.08)

    /// Layout metrics shared between the gutter and every strip so their rows
    /// stay pixel-aligned. Rows are fixed-height (not a `Grid`) specifically so
    /// each strip can still paint one continuous background panel behind all
    /// of its rows.
    enum Metrics {
        static let gutterWidth: CGFloat       = 90
        static let stripWidth: CGFloat        = 125
        static let rowSpacing: CGFloat        = 6
        static let controlRowHeight: CGFloat  = 22
        static let panRowHeight: CGFloat      = 46
        static let faderRowMinHeight: CGFloat = 220
        static let namePlateHeight: CGFloat   = 22
    }
}

/// One row in the console layout, in top-to-bottom order. Both
/// `ConsoleGutterView` and `ConsoleStripView` iterate this same list so their
/// rows always line up — this is the single source of truth for row order,
/// labels, and heights.
enum ConsoleRow: CaseIterable, Hashable {
    case device, channels, output, pan, dbValue, faderAndMeter, muteSolo, namePlate

    /// Gutter label. Empty for rows that are purely visual (the fader/meter
    /// region and the bottom name plate carry no row label in Logic either).
    var label: String {
        switch self {
        case .device: "Device"
        case .channels: "Channels"
        case .output: "Output"
        case .pan: "Pan"
        case .dbValue: "dB"
        case .faderAndMeter: ""
        case .muteSolo: "Mute / Solo"
        case .namePlate: ""
        }
    }

    var height: CGFloat {
        switch self {
        case .device, .channels, .output, .dbValue, .muteSolo:
            MixerTheme.Metrics.controlRowHeight
        case .pan:
            MixerTheme.Metrics.panRowHeight
        case .faderAndMeter:
            MixerTheme.Metrics.faderRowMinHeight
        case .namePlate:
            MixerTheme.Metrics.namePlateHeight
        }
    }
}

/// Left-hand row-label gutter. Must render `ConsoleRow.allCases` in order with
/// identical per-row heights to `ConsoleStripView` so labels line up.
struct ConsoleGutterView: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: MixerTheme.Metrics.rowSpacing) {
            ForEach(ConsoleRow.allCases, id: \.self) { row in
                Text(row.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MixerTheme.gutterText)
                    .frame(height: row.height, alignment: row == .faderAndMeter ? .top : .center)
            }
        }
        .frame(width: MixerTheme.Metrics.gutterWidth, alignment: .trailing)
        .padding(.trailing, 8)
    }
}
