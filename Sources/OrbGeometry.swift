import CoreGraphics

/// The orb's measurements at a given size.
///
/// A value type with no AppKit in it, for the same reason `RingGeometry` is one:
/// the drawing and the hit test both read from a single instance, so they cannot
/// end up disagreeing about where a dot is, and the arithmetic can be tested
/// without a screen.
struct OrbGeometry: Equatable {
    /// Below 36pt the dots stop being distinguishable; above 76pt the orb stops
    /// reading as a button and starts reading as a window.
    static let minSize: CGFloat = 36
    static let maxSize: CGFloat = 76
    static let defaultSize: CGFloat = 56

    let size: CGFloat

    init(size: CGFloat) {
        guard size.isFinite else {
            self.size = Self.defaultSize
            return
        }
        self.size = min(max(size, Self.minSize), Self.maxSize)
    }

    var radius: CGFloat { size / 2 }
    var dotRingRadius: CGFloat { 0.30 * size }
    /// Slot 0's dot, drawn larger so the orb has a visible orientation rather
    /// than reading as a symmetrical smear of colour.
    var leadDotRadius: CGFloat { 0.075 * size }
    var dotRadius: CGFloat { 0.055 * size }
    var centreDotRadius: CGFloat { 0.035 * size }

    /// The centre of one dot, in the orb's own coordinates, with the outer ring's
    /// rotation applied so a turned wheel and the orb agree about which app is at
    /// the top.
    func dotCenter(index: Int, count: Int, rotation: CGFloat) -> CGPoint {
        let centre = CGPoint(x: radius, y: radius)
        guard count > 0 else { return centre }
        let turn = rotation.isFinite ? rotation : 0
        let angle = CGFloat.pi / 2 - 2 * CGFloat.pi * CGFloat(index) / CGFloat(count) - turn
        return CGPoint(x: centre.x + cos(angle) * dotRingRadius,
                       y: centre.y + sin(angle) * dotRingRadius)
    }

    /// Whether a point in the orb's own coordinates is on the disc.
    ///
    /// The panel is square, so without this the corners would swallow clicks
    /// aimed at whatever is behind the orb.
    func contains(_ point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        return hypot(point.x - radius, point.y - radius) <= radius
    }
}
