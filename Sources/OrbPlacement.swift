import CoreGraphics

/// Which screen edge the orb is parked against.
enum OrbEdge: String, CaseIterable {
    case none, left, right, top, bottom
}

/// Where the orb is allowed to sit, and how its position is stored.
///
/// Pure and free of AppKit so it links into the test binary: the interesting
/// cases are screens that are not attached to this machine, and positions saved
/// by a display that has since been unplugged.
struct OrbPlacement {
    /// How close to an edge counts as parked there.
    static let edgeThreshold: CGFloat = 14
    /// How much of the orb slides off the edge when tucked.
    static let tuckFraction: CGFloat = 0.62

    /// Keeps the whole orb inside `visible`.
    ///
    /// The upper bound subtracts the orb's own size, so it is the orb that stays
    /// on screen rather than merely its origin. A screen smaller than the orb
    /// would invert the range, so that case falls back to the near edge.
    static func clamp(_ origin: CGPoint, size: CGFloat, in visible: CGRect) -> CGPoint {
        let x = origin.x.isFinite ? origin.x : visible.midX
        let y = origin.y.isFinite ? origin.y : visible.midY
        let maxX = visible.maxX - size
        let maxY = visible.maxY - size
        return CGPoint(x: maxX >= visible.minX ? min(max(x, visible.minX), maxX) : visible.minX,
                       y: maxY >= visible.minY ? min(max(y, visible.minY), maxY) : visible.minY)
    }

    /// The edge the orb is parked against, or `.none`.
    ///
    /// A corner is within the threshold of two edges at once. The horizontal edge
    /// wins, because sliding sideways hides less of a circle's silhouette than
    /// sliding up or down does.
    static func nearestEdge(origin: CGPoint, size: CGFloat,
                            in visible: CGRect) -> OrbEdge {
        guard origin.x.isFinite, origin.y.isFinite else { return .none }
        if origin.x - visible.minX <= edgeThreshold { return .left }
        if visible.maxX - (origin.x + size) <= edgeThreshold { return .right }
        if origin.y - visible.minY <= edgeThreshold { return .bottom }
        if visible.maxY - (origin.y + size) <= edgeThreshold { return .top }
        return .none
    }

    /// Where the orb sits while tucked away at `edge`.
    static func tuckedOrigin(_ origin: CGPoint, size: CGFloat, in visible: CGRect,
                             edge: OrbEdge) -> CGPoint {
        let offset = size * tuckFraction
        switch edge {
        case .none: return origin
        case .left: return CGPoint(x: origin.x - offset, y: origin.y)
        case .right: return CGPoint(x: origin.x + offset, y: origin.y)
        case .bottom: return CGPoint(x: origin.x, y: origin.y - offset)
        case .top: return CGPoint(x: origin.x, y: origin.y + offset)
        }
    }

    /// The orb's position as a fraction of the room it has on this screen.
    ///
    /// Stored rather than an absolute point so the orb comes back in the same
    /// relative place after a resolution change or a move to another display.
    /// The denominator is the *travel* available to the origin, not the screen
    /// width, which is what makes the round trip exact at both extremes.
    static func fraction(ofOrigin origin: CGPoint, size: CGFloat,
                         in visible: CGRect) -> CGPoint {
        let travelX = visible.width - size
        let travelY = visible.height - size
        let fx = travelX > 0 ? (origin.x - visible.minX) / travelX : 0
        let fy = travelY > 0 ? (origin.y - visible.minY) / travelY : 0
        return CGPoint(x: unit(fx), y: unit(fy))
    }

    /// The inverse, clamped, so a saved position that no longer fits still lands
    /// somewhere the user can reach.
    static func origin(fromFraction fraction: CGPoint, size: CGFloat,
                       in visible: CGRect) -> CGPoint {
        let fx = unit(fraction.x)
        let fy = unit(fraction.y)
        let proposed = CGPoint(x: visible.minX + (visible.width - size) * fx,
                               y: visible.minY + (visible.height - size) * fy)
        return clamp(proposed, size: size, in: visible)
    }

    private static func unit(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}
