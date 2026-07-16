// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop, commit 3b632db5
// Original files: Loop/Extensions/Angle+Extensions.swift,
//                 Loop/Extensions/CGGeometry+Extensions.swift
//
// Only the helper functions the vendored radial ring (Angle.normalized,
// Angle.angleDifference) and the vendored snap animation (the CGGeometry
// approximate-equality, pushInside, fitting, and getEdgesTouchingBounds
// helpers) actually reference are carried over — verbatim in body, with the
// unused remainder of both source files dropped.

import SwiftUI

extension Angle {
    /// Wraps a raw angle into [0°, 360°). Used by the direction-selector
    /// square segment to trim a `RoundedRectangle` on a stable 0…1 fraction.
    func normalized() -> Angle {
        let degrees = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)

        return Angle(degrees: degrees)
    }

    /// Signed shortest rotation from `self` to `angle2`, in (−180°, 180°].
    /// The ring animates its highlight along this shortest path so the wedge
    /// never spins the long way round at the 0°/360° seam.
    func angleDifference(to angle2: Angle) -> Angle {
        let angle1 = degrees
        let angle2 = angle2.degrees
        let diff: Double = (angle2 - angle1 + 180.0).truncatingRemainder(dividingBy: 360.0) - 180.0
        return Angle(degrees: diff < -180 ? diff + 360 : diff)
    }
}

extension CGFloat {
    func approximatelyEquals(to comparison: CGFloat, tolerance: CGFloat = 10) -> Bool {
        abs(self - comparison) < tolerance
    }
}

extension CGPoint {
    func approximatelyEqual(to point: CGPoint, tolerance: CGFloat = 10) -> Bool {
        abs(x - point.x) < tolerance &&
            abs(y - point.y) < tolerance
    }
}

extension CGSize {
    func approximatelyEqual(to size: CGSize, tolerance: CGFloat = 10) -> Bool {
        abs(width - size.width) < tolerance && abs(height - size.height) < tolerance
    }

    /// Largest size with the given aspect ratio that still fits inside `self`.
    /// The animation uses this to predict where a fixed-aspect-ratio window
    /// will land so it can re-anchor mid-flight instead of jittering.
    func fitting(aspectRatio: CGFloat) -> CGSize {
        guard width > 0, height > 0, aspectRatio > 0 else {
            return self
        }

        let sizeAspectRatio = width / height
        if sizeAspectRatio > aspectRatio {
            return CGSize(width: height * aspectRatio, height: height)
        } else {
            return CGSize(width: width, height: width / aspectRatio)
        }
    }
}

extension CGRect {
    /// Nudges the rect back inside `rect2` without resizing it, so a re-anchored
    /// frame never spills past the screen's visible bounds.
    func pushInside(_ rect2: CGRect) -> CGRect {
        var result = self

        if result.minX < rect2.minX {
            result.origin.x = rect2.minX
        }

        if result.minY < rect2.minY {
            result.origin.y = rect2.minY
        }

        if result.maxX > rect2.maxX {
            result.origin.x = rect2.maxX - result.width
        }

        if result.maxY > rect2.maxY {
            result.origin.y = rect2.maxY - result.height
        }

        return result
    }

    /// Which edges of `self` line up with `rect2`'s edges (the screen bounds).
    /// The animation pins the window to whichever edges its target touched, so
    /// a size the app clamps still lands flush against the intended edge.
    func getEdgesTouchingBounds(_ rect2: CGRect) -> Edge.Set {
        var result: Edge.Set = []

        if minX.approximatelyEquals(to: rect2.minX) {
            result.insert(.leading)
        }

        if minY.approximatelyEquals(to: rect2.minY) {
            result.insert(.top)
        }

        if maxX.approximatelyEquals(to: rect2.maxX) {
            result.insert(.trailing)
        }

        if maxY.approximatelyEquals(to: rect2.maxY) {
            result.insert(.bottom)
        }

        return result
    }
}
