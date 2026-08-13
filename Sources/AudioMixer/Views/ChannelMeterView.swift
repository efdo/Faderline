import SwiftUI

/// A vertical stereo level meter: two bars (L/R) sharing the fader's dB
/// scale (via `FaderTaper`), each with a peak-hold marker and gradient
/// coloring, plus a clip indicator above that latches until tapped.
struct ChannelMeterView: View {
    let meter: MeterViewModel
    let onResetClip: () -> Void

    @State private var heldLeft = PeakHold()
    @State private var heldRight = PeakHold()

    var body: some View {
        VStack(spacing: 2) {
            clipIndicator
            HStack(spacing: 2) {
                barView(level: meter.levelLeft, displayPeak: heldLeft.displayValue(at: meter.timestamp))
                barView(level: meter.levelRight, displayPeak: heldRight.displayValue(at: meter.timestamp))
            }
        }
        .onChange(of: meter.peakLeft) { _, newValue in heldLeft.register(newValue, at: meter.timestamp) }
        .onChange(of: meter.peakRight) { _, newValue in heldRight.register(newValue, at: meter.timestamp) }
    }

    private var clipIndicator: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(meter.clipped ? MixerTheme.clipOn : MixerTheme.clipOff)
            .frame(height: 6)
            .contentShape(Rectangle())
            .onTapGesture(perform: onResetClip)
    }

    private func barView(level: Float, displayPeak: Float) -> some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let levelPosition = CGFloat(FaderTaper.position(forDB: FaderTaper.db(forGain: level)))
            let peakPosition = CGFloat(FaderTaper.position(forDB: FaderTaper.db(forGain: displayPeak)))

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(MixerTheme.meterBg)

                // Full-height gradient, revealed only up to the current level
                // via a bottom-aligned mask. This keeps every color's
                // absolute dB position fixed regardless of the lit portion's
                // height (masking a pre-drawn gradient, rather than filling a
                // shorter shape with a gradient that would rescale to fit it).
                meterGradient
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: height * levelPosition)
                    }

                Rectangle()
                    .fill(MixerTheme.meterPeakMarker)
                    .frame(height: 2)
                    .offset(y: -height * peakPosition)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    /// Green below -12 dB, amber -12...-3 dB, red above -3 dB. Stops are
    /// placed via `FaderTaper.position(forDB:)` so the color boundaries land
    /// at the same physical height as the fader's own scale ticks.
    private var meterGradient: LinearGradient {
        let low = CGFloat(FaderTaper.position(forDB: -12))
        let high = CGFloat(FaderTaper.position(forDB: -3))
        return LinearGradient(
            stops: [
                .init(color: MixerTheme.meterLow, location: 0.0),
                .init(color: MixerTheme.meterLow, location: low),
                .init(color: MixerTheme.meterMid, location: low),
                .init(color: MixerTheme.meterMid, location: high),
                .init(color: MixerTheme.meterHigh, location: high),
                .init(color: MixerTheme.meterHigh, location: 1.0),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

/// Tracks a decaying peak-hold value for one meter channel: holds the
/// highest recent sample for `holdDuration`, then decays linearly in dB
/// (i.e. exponentially in linear gain) at `decayDbPerSecond`.
///
/// This exists because the underlying peak feed (`HALMixerEngine.
/// inputPeaks`/`outputPeak`) only reports "peak since the last ~33 ms poll" —
/// far too brief to track visually — so the hold/decay has to happen here,
/// purely as a function of elapsed wall-clock time (no timers to manage).
///
/// Internal (not `private`) so `PeakHoldTests` can exercise it directly.
struct PeakHold {
    static let holdDuration: TimeInterval = 1.2
    static let decayDbPerSecond: Float = 20

    private var value: Float = 0
    private var peakedAt: Date = .distantPast

    /// Registers a new sample. Compares against the *currently displayed*
    /// (already-decayed) value at `date`, not the frozen historical peak —
    /// otherwise, once any loud transient occurs, every subsequent
    /// quieter-but-genuine peak would be silently dropped forever (it would
    /// never again be `>= ` the old all-time high), leaving the meter stuck
    /// reading "no signal" even while real, just-quieter audio keeps flowing.
    mutating func register(_ newValue: Float, at date: Date = Date()) {
        if newValue >= displayValue(at: date) {
            value = newValue
            peakedAt = date
        }
    }

    func displayValue(at date: Date) -> Float {
        let elapsed = date.timeIntervalSince(peakedAt)
        guard elapsed > Self.holdDuration else { return value }
        let decayElapsed = Float(elapsed - Self.holdDuration)
        let db = FaderTaper.db(forGain: value) - Self.decayDbPerSecond * decayElapsed
        return FaderTaper.gain(forDB: db)
    }
}
