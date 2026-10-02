import SwiftUI

/// A circular pan/balance knob. Drag vertically to adjust, double-click to
/// recenter. A small drag dead zone snaps to center. See
/// `FaderTaper.panGains(_:)` for how `pan` maps to L/R gain.
struct PanKnobView: View {
    /// -1 (hard left) ... 0 (center) ... +1 (hard right).
    @Binding var pan: Float

    @State private var dragStartPan: Float?

    /// The knob sweeps ~270°, like a physical pan pot, centered at 12 o'clock.
    private let minAngle: Double = -135
    private let maxAngle: Double = 135

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let angle = Angle(degrees: minAngle + (Double(pan) + 1) / 2 * (maxAngle - minAngle))

            ZStack {
                Circle()
                    .fill(MixerTheme.knobFill)
                    .overlay(Circle().strokeBorder(MixerTheme.faderCapEdge, lineWidth: 1))

                // Fixed center (0 pan) detent tick at 12 o'clock — never rotates.
                KnobIndicatorShape(innerFraction: 0.78, outerFraction: 0.95)
                    .stroke(MixerTheme.scaleTick, lineWidth: 1)
                    .frame(width: size, height: size)

                // Value indicator. Drawn full-frame so `.rotationEffect`'s
                // default center anchor pivots exactly around the knob's
                // center, not around the (shorter) line's own bounds.
                KnobIndicatorShape(innerFraction: 0.15, outerFraction: 0.80)
                    .stroke(MixerTheme.knobIndicator, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: size, height: size)
                    .rotationEffect(angle)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
            .gesture(
                TapGesture(count: 2)
                    .onEnded { pan = 0 }
                    .exclusively(
                        before: DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragStartPan == nil {
                                    dragStartPan = pan
                                }
                                guard let start = dragStartPan else { return }
                                pan = Self.pan(
                                    forDragTranslation: value.translation.height,
                                    startPan: start,
                                    diameter: size
                                )
                            }
                            .onEnded { _ in
                                dragStartPan = nil
                            }
                    )
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    static func pan(forDragTranslation translation: CGFloat, startPan: Float, diameter: CGFloat) -> Float {
        // Use the unsnapped gesture origin so dragging through center never gets stuck.
        let delta = Float(-translation) / Float(max(diameter, 1)) * 2
        let value = min(max(startPan + delta, -1), 1)
        return abs(value) <= 0.08 ? 0 : value
    }
}

/// A radial line from `innerFraction` to `outerFraction` of the knob's
/// radius, drawn pointing straight up from center within a full-size frame.
/// Used both for the fixed center-detent tick and (rotated) for the live pan
/// indicator — rotating a full-frame shape pivots correctly around the
/// knob's own center.
private struct KnobIndicatorShape: Shape {
    var innerFraction: CGFloat
    var outerFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - radius * innerFraction))
        path.addLine(to: CGPoint(x: center.x, y: center.y - radius * outerFraction))
        return path
    }
}
