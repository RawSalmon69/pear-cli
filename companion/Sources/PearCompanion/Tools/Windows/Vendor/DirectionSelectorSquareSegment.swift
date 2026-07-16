// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop, commit 3b632db5
// Original file: Loop/Window Action Indicators/Radial Menu/DirectionSelectorSquareSegment.swift
//
// Verbatim. The masked wedge used when the ring's corner radius makes a
// rounded rectangle rather than a circle: it trims the rounded-rect stroke on
// the target side and its 180° mirror. Depends on `Angle.normalized()`
// (vendored in LoopHelpers.swift).

import SwiftUI

struct DirectionSelectorSquareSegment: View {
    var angle: Double = .zero
    let radialMenuCornerRadius: CGFloat
    let radialMenuThickness: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radialMenuCornerRadius)
                .trim(
                    from: Angle(degrees: angle - 22.5).normalized().degrees / 360.0,
                    to: Angle(degrees: angle + 22.5).normalized().degrees / 360.0
                )
                .stroke(.white, lineWidth: radialMenuThickness * 2)

            RoundedRectangle(cornerRadius: radialMenuCornerRadius)
                .trim(
                    from: Angle(degrees: angle - 180 - 22.5).normalized().degrees / 360.0,
                    to: Angle(degrees: angle - 180 + 22.5).normalized().degrees / 360.0
                )
                .stroke(.white, lineWidth: radialMenuThickness * 2)
                .rotationEffect(.degrees(180))
        }
    }
}
