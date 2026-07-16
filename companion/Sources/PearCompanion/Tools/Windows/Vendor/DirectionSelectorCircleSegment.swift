// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop, commit 3b632db5
// Original file: Loop/Window Action Indicators/Radial Menu/DirectionSelectorCircleSegment.swift
//
// Verbatim. The masked wedge used when the ring's corner radius is large
// enough to be a true circle: a ±22.5° arc at `angle`, with `animatableData`
// on the angle so the highlight glides between sectors.

import SwiftUI

struct DirectionSelectorCircleSegment: Shape {
    var angle: Double = .zero
    let radialMenuSize: CGFloat

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func path(in _: CGRect) -> Path {
        var path = Path()

        path.move(
            to: CGPoint(
                x: radialMenuSize / 2,
                y: radialMenuSize / 2
            )
        )
        path.addArc(
            center: CGPoint(
                x: radialMenuSize / 2,
                y: radialMenuSize / 2
            ),
            radius: radialMenuSize,
            startAngle: .degrees(angle - 22.5),
            endAngle: .degrees(angle + 22.5),
            clockwise: false
        )

        return path
    }
}
