// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop, commit 3b632db5
// Original file: Loop/Utilities/VisualEffectView.swift
//
// Verbatim: the pre-Tahoe blur backing for the radial ring and the zone
// preview. On macOS 26 the ring uses `.glassEffect`; below it, this wraps
// `NSVisualEffectView` so the ring/preview keep a real material blur.

import SwiftUI

/// SwiftUI view for NSVisualEffect
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State?

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        state: NSVisualEffectView.State? = nil
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode

        if let state {
            visualEffectView.state = state
        }

        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context _: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}
