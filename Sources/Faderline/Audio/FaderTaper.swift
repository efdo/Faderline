import Foundation

/// Pure math for the console fader: dB ↔ normalized position ↔ linear gain,
/// plus the pan/balance law used by input strips.
///
/// The fader is **not** linear-in-dB. Like most professional consoles (and
/// Logic Pro), resolution is denser near unity (0 dB) and compressed toward
/// the bottom of the travel. This is modeled with a piecewise-linear
/// breakpoint table over (position, dB) pairs; the same breakpoints double as
/// the tick marks drawn next to the fader and on the meter scale, so the
/// fader's travel and the meter's dB readings always line up visually.
///
/// No UI imports — this type is pure math and is unit-tested directly.
enum FaderTaper {
    /// Top of fader travel.
    static let maxDB: Float = 6
    /// Bottom of usable fader travel. Below this, gain is treated as exactly 0.
    static let minDB: Float = -60

    /// (position 0...1 bottom→top, dB). Position 0.80 is unity (0 dB),
    /// matching the Logic Pro fader scale; position 1.00 is +6 dB (top).
    /// Position 0 itself is special-cased to `-.infinity` (see `db(forPosition:)`)
    /// so the very bottom of the fader is a hard "off", not just -60 dB.
    static let breakpoints: [(p: Float, db: Float)] = [
        (0.00, -60), (0.05, -50), (0.13, -40), (0.21, -30), (0.26, -25),
        (0.32, -20), (0.40, -15), (0.50, -10), (0.62, -5), (0.70, -3),
        (0.80, 0), (0.90, 3), (1.00, 6),
    ]

    /// dB values at which tick marks are drawn next to the fader and on the meter scale.
    static let scaleTicks: [Float] = [6, 3, 0, -3, -5, -10, -15, -20, -25, -30, -40, -60]

    // MARK: - Position ↔ dB

    /// Converts a fader position (0...1) to a dB value via the breakpoint table.
    /// Position `0` maps to `-.infinity` (true silence) rather than the table's
    /// nominal -60 dB floor — the last sliver of downward travel is a hard cliff to off,
    /// matching how physical console faders behave at the very bottom of their throw.
    static func db(forPosition p: Float) -> Float {
        let clamped = min(max(p, 0), 1)
        if clamped <= 0 { return -.infinity }
        if clamped >= 1 { return breakpoints.last!.db }

        for i in 1..<breakpoints.count {
            let lo = breakpoints[i - 1]
            let hi = breakpoints[i]
            if clamped <= hi.p {
                guard hi.p > lo.p else { return hi.db }
                let t = (clamped - lo.p) / (hi.p - lo.p)
                return lo.db + t * (hi.db - lo.db)
            }
        }
        return breakpoints.last!.db
    }

    /// Converts a dB value to a fader position (0...1); the inverse of `db(forPosition:)`.
    /// `-.infinity` and any value at or below the table's floor (-60 dB) both map to position 0.
    static func position(forDB db: Float) -> Float {
        if db.isNaN { return 0 }
        if db.isInfinite && db < 0 { return 0 }
        if db <= breakpoints.first!.db { return 0 }
        if db >= breakpoints.last!.db { return 1 }

        for i in 1..<breakpoints.count {
            let lo = breakpoints[i - 1]
            let hi = breakpoints[i]
            if db <= hi.db {
                guard hi.db > lo.db else { return hi.p }
                let t = (db - lo.db) / (hi.db - lo.db)
                return lo.p + t * (hi.p - lo.p)
            }
        }
        return 1
    }

    // MARK: - dB ↔ linear gain

    /// Converts a dB value to linear gain. Anything at or below `minDB`
    /// (including `-.infinity`) yields exactly `0`, so a fader parked at the
    /// bottom is truly silent rather than merely very quiet.
    static func gain(forDB db: Float) -> Float {
        if db.isNaN { return 0 }
        if db <= minDB { return 0 }
        return pow(10, db / 20)
    }

    /// Converts linear gain to dB. `g <= 0` yields `-.infinity`.
    static func db(forGain g: Float) -> Float {
        guard g > 0 else { return -.infinity }
        return 20 * log10(g)
    }

    // MARK: - Display

    /// Human-readable dB string for the strip's numeric field, e.g. "0.0", "-6.0", "-∞".
    static func displayString(forDB db: Float) -> String {
        if db.isInfinite && db < 0 { return "-\u{221E}" }
        return String(format: "%.1f", db)
    }

    /// Parses a user-typed dB string, accepting "-inf"/"-∞" for silence or any
    /// numeric string. Returns `nil` for unparseable input. Finite results are
    /// clamped to `minDB...maxDB`.
    static func parseDB(_ text: String) -> Float? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        if lowered == "-inf" || lowered == "-\u{221E}" || lowered == "\u{221E}" {
            return -.infinity
        }
        guard let value = Float(trimmed), !value.isNaN else { return nil }
        return min(max(value, minDB), maxDB)
    }

    // MARK: - Pan / balance law

    /// Constant-power pan/balance law with a **0 dB center** (not the traditional
    /// -3 dB center), so a strip's default centered pan is a no-op relative to
    /// existing un-panned levels — panning must not change anyone's mix on upgrade.
    ///
    /// `pan` in `[-1, +1]`: -1 = hard left, 0 = center, +1 = hard right.
    /// At center both channels are unity (1.0, 1.0). At the hard extremes the
    /// "open" channel reaches `√2` (≈ +3 dB) while the other reaches `0`. This
    /// trades a little extra headroom at the extremes for a no-op center, which
    /// is acceptable given the master clip indicator.
    static func panGains(_ pan: Float) -> (left: Float, right: Float) {
        let clamped = min(max(pan, -1), 1)
        let angle = (clamped + 1) * (Float.pi / 4) // 0 ... pi/2
        let sqrt2 = Float(2).squareRoot()
        return (left: cos(angle) * sqrt2, right: sin(angle) * sqrt2)
    }
}
