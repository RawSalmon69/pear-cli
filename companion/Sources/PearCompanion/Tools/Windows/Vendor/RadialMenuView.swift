// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop, commit 3b632db5
// Original file: Loop/Window Action Indicators/Radial Menu/RadialMenuView.swift
//
// The ring rendering is Loop's, verbatim in structure: the masked wedge
// (circle vs. trimmed rounded-rect by corner radius), the accent-gradient
// fill, the glass/blur backing, and the two render paths gated on
// `#available(macOS 26.0, *)` (`.glassEffect` on Tahoe, `VisualEffectView`
// below). Only the viewmodel seam changed:
//   • Loop's `RadialMenuViewModel` (wired to its 90-case WindowAction domain)
//     becomes our `RadialRingModel` (fed a `WindowZone?` selection).
//   • Loop's `Defaults[.radialMenu*]` reads become `@AppStorage` over the
//     `windows.*` keys, so the sliders apply live.
//   • Loop's `AccentColorController` gradient becomes `Theme.accent`.
//   • Luminare's `\.luminareAnimation` becomes the speed picker's curve; the
//     Scribe logging and `appearsActive` gate are dropped (the ring is always
//     active feedback, so the pre-Tahoe-style inner border always renders).

import SwiftUI

struct RadialMenuView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var viewModel: RadialRingModel
    private let radialMenuSize: CGFloat = 100

    @AppStorage(WindowSettings.Key.ringCornerRadius)
    private var cornerRadiusStore = WindowSettings.defaultRingCornerRadius
    @AppStorage(WindowSettings.Key.ringThickness)
    private var thicknessStore = WindowSettings.defaultRingThickness
    @AppStorage(WindowSettings.Key.animationSpeed)
    private var speedStore = WindowSettings.defaultAnimationSpeed.rawValue

    init(viewModel: RadialRingModel) {
        self.viewModel = viewModel
    }

    private var radialMenuCornerRadius: CGFloat {
        CGFloat(min(max(cornerRadiusStore, WindowSettings.ringCornerRadiusRange.lowerBound),
                    WindowSettings.ringCornerRadiusRange.upperBound))
    }

    private var radialMenuThickness: CGFloat {
        CGFloat(min(max(thicknessStore, WindowSettings.ringThicknessRange.lowerBound),
                    WindowSettings.ringThicknessRange.upperBound))
    }

    private var speed: WindowAnimationSpeed {
        WindowAnimationSpeed(rawValue: speedStore) ?? WindowSettings.defaultAnimationSpeed
    }

    /// Pear feeds its single accent into both of Loop's gradient stops — the
    /// "trivial, non-degrading" theme touch (matches Loop's non-gradient default).
    private var accent: Color { Theme.accent }

    var body: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                postTahoeView()
            } else {
                preTahoeView()
            }
        }
        .padding(40)
        .fixedSize()
        .animation(speed.radialMenuSize, value: viewModel.selection)
    }

    @available(macOS 26.0, *)
    private func postTahoeView() -> some View {
        ZStack {
            if viewModel.isShown {
                ZStack {
                    radialMenuFill()
                        .mask(directionSelectorMask)
                        .glassEffect(
                            .regular.tint(accent.opacity(0.025)),
                            in: .rect(cornerRadius: radialMenuCornerRadius)
                        )
                        .mask(radialMenuMask)

                    let borderColor: Color = colorScheme == .dark
                        ? .white.opacity(0.25).mix(with: accent, by: 0.25)
                        : .white

                    // Masked glass loses its inner border; re-emulate it.
                    let innerBorderThickness: CGFloat = 0.5
                    RoundedRectangle(cornerRadius: radialMenuCornerRadius)
                        .inset(by: radialMenuThickness - innerBorderThickness)
                        .strokeBorder(lineWidth: innerBorderThickness)
                        .foregroundStyle(borderColor)
                        .mask {
                            LinearGradient(
                                colors: [.white, .clear, .white],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        }

                    overlayImage()
                }
                .transition(.scale(scale: 1.25).combined(with: .opacity))
            }
        }
        .compositingGroup()
        .frame(width: radialMenuSize, height: radialMenuSize)
        .shadow(color: .black.opacity(viewModel.isShadowShown ? 0.2 : 0), radius: 10)
        .scaleEffect(viewModel.shouldFillRadialMenu ? 0.85 : 1.0)
    }

    private func preTahoeView() -> some View {
        ZStack {
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, state: .active)

                radialMenuFill()
                    .mask(directionSelectorMask)

                radialMenuBorder()
            }
            .mask(radialMenuMask)

            overlayImage()
        }
        .frame(width: radialMenuSize, height: radialMenuSize)
        .shadow(radius: 10)
        .compositingGroup()
        .opacity(viewModel.isShown ? 1 : 0)
        .scaleEffect(viewModel.shouldFillRadialMenu ? 0.85 : 1.0)
    }

    private func radialMenuFill() -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [accent, accent]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private func directionSelectorMask() -> some View {
        ZStack {
            if viewModel.shouldFillRadialMenu {
                Color.white
            } else {
                ZStack {
                    if radialMenuCornerRadius >= radialMenuSize / 2 - 2 {
                        DirectionSelectorCircleSegment(
                            angle: viewModel.angle,
                            radialMenuSize: radialMenuSize
                        )
                    } else {
                        DirectionSelectorSquareSegment(
                            angle: viewModel.angle,
                            radialMenuCornerRadius: radialMenuCornerRadius,
                            radialMenuThickness: radialMenuThickness
                        )
                    }
                }
                .compositingGroup()
                .opacity(viewModel.shouldHideDirectionSelector ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func radialMenuBorder() -> some View {
        ZStack {
            if radialMenuCornerRadius >= radialMenuSize / 2 - 2 {
                Circle()
                    .stroke(.quinary, lineWidth: 2)

                Circle()
                    .stroke(.quinary, lineWidth: 2)
                    .padding(radialMenuThickness)
            } else {
                RoundedRectangle(cornerRadius: radialMenuCornerRadius)
                    .stroke(.quinary, lineWidth: 2)

                RoundedRectangle(cornerRadius: radialMenuCornerRadius - radialMenuThickness)
                    .stroke(.quinary, lineWidth: 2)
                    .padding(radialMenuThickness)
            }
        }
    }

    private func radialMenuMask() -> some View {
        ZStack {
            if radialMenuCornerRadius >= radialMenuSize / 2 - 2 {
                Circle()
                    .strokeBorder(.black, lineWidth: radialMenuThickness)
            } else {
                RoundedRectangle(cornerRadius: radialMenuCornerRadius)
                    .strokeBorder(.black, lineWidth: radialMenuThickness)
            }
        }
    }

    private func overlayImage() -> some View {
        ZStack {
            if let image = viewModel.radialMenuImage {
                if #available(macOS 26.0, *) {
                    image
                        .transition(.symbolEffect(.drawOn, options: .speed(2)))
                        .contentTransition(.symbolEffect(.replace, options: .speed(2)))
                } else {
                    image
                }
            }
        }
        .foregroundStyle(accent)
        .font(.system(size: 20, weight: .bold))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
