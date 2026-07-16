import CoreGraphics
import XCTest

@testable import PearCompanion

/// Pure math behind the sunburst viewport (zoom clamp, anchor stability, pan
/// bounds, offset reset) and the treemap tooltip placement (edge-flip, clamp).
/// Both are vendored verbatim from Radix (MIT); these cases pin the behavior we
/// rely on when wiring them into our charts.

final class SunburstViewportTransformTests: XCTestCase {
    private let baseFrame = CGRect(x: 10, y: 20, width: 200, height: 100)

    // MARK: Identity

    func testIdentityIsNotZoomedAndCoversBaseFrameExactly() {
        let identity = SunburstViewportTransform.identity
        XCTAssertEqual(identity.scale, 1)
        XCTAssertEqual(identity.offset, .zero)
        XCTAssertFalse(identity.isZoomed)
        XCTAssertEqual(identity.frame(for: baseFrame), baseFrame)
    }

    func testInitClampsSubMinimumScaleAndDropsOffset() {
        // A scale at/below the minimum can't hold an offset — it must reset.
        let transform = SunburstViewportTransform(scale: 0.5, offset: CGSize(width: 30, height: 30))
        XCTAssertEqual(transform.scale, 1)
        XCTAssertEqual(transform.offset, .zero)
        XCTAssertFalse(transform.isZoomed)
    }

    // MARK: Zoom

    func testZoomExpandsChartAroundBaseCenter() {
        let transform = SunburstViewportTransform().zoomed(by: 2, anchor: nil, in: baseFrame)
        XCTAssertEqual(transform.scale, 2)
        XCTAssertEqual(transform.offset, .zero)
        XCTAssertEqual(transform.frame(for: baseFrame), CGRect(x: -90, y: -30, width: 400, height: 200))
    }

    func testZoomClampsToMaximumScale() {
        let transform = SunburstViewportTransform().zoomed(by: 10, anchor: nil, in: baseFrame)
        XCTAssertEqual(transform.scale, SunburstViewportTransform.maximumScale)
    }

    func testZoomRespectsCustomMaximumScale() {
        let transform = SunburstViewportTransform().zoomed(
            by: 4, anchor: nil, in: CGRect(x: 0, y: 0, width: 200, height: 100), maximumScale: 2)
        XCTAssertEqual(transform.scale, 2)
    }

    func testZoomAroundAnchorKeepsAnchoredPointStable() throws {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let anchor = CGPoint(x: 150, y: 100)
        let transform = SunburstViewportTransform().zoomed(by: 2, anchor: anchor, in: frame)

        let local = try XCTUnwrap(transform.localChartPoint(for: anchor, in: frame))
        XCTAssertEqual(transform.offset, CGSize(width: -50, height: 0))
        XCTAssertEqual(local.point, CGPoint(x: 300, y: 200))
        XCTAssertEqual(local.size, CGSize(width: 400, height: 400))
    }

    func testZoomOutToMinimumResetsOffset() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let transform = SunburstViewportTransform(scale: 2, offset: CGSize(width: 40, height: -20))
            .zoomed(by: 0.1, anchor: CGPoint(x: 50, y: 25), in: frame)
        XCTAssertEqual(transform, .identity)
    }

    // MARK: Pan

    func testPanIsIgnoredWhenNotZoomed() {
        let transform = SunburstViewportTransform().panned(by: CGSize(width: 50, height: 50), in: baseFrame)
        XCTAssertEqual(transform, .identity)
    }

    func testPanOffsetIsConstrainedToKeepBaseFrameCovered() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let transform = SunburstViewportTransform(scale: 2)
            .panned(by: CGSize(width: 500, height: -500), in: frame)
        XCTAssertEqual(transform.offset, CGSize(width: 100, height: -50))
        XCTAssertTrue(transform.frame(for: frame).contains(frame))
    }

    func testConstrainedShrinksOffsetForSmallerFrame() {
        let smaller = CGRect(x: 0, y: 0, width: 120, height: 80)
        let transform = SunburstViewportTransform(scale: 2, offset: CGSize(width: 100, height: -100))
            .constrained(to: smaller)
        XCTAssertEqual(transform.offset, CGSize(width: 60, height: -40))
        XCTAssertTrue(transform.frame(for: smaller).contains(smaller))
    }

    // MARK: localChartPoint

    func testLocalChartPointReturnsNilOutsideFrame() {
        let identity = SunburstViewportTransform.identity
        XCTAssertNil(identity.localChartPoint(for: CGPoint(x: 500, y: 500), in: baseFrame))
    }
}

final class TreemapTooltipPlacementTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
    private let tooltipSize = CGSize(width: 200, height: 80)

    func testPlacesTooltipBelowAndRightWhenSpaceIsAvailable() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 100, y: 100), tooltipSize: tooltipSize, in: bounds)
        XCTAssertEqual(origin, CGPoint(x: 114, y: 114))
    }

    func testFlipsTooltipLeftNearRightEdge() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 580, y: 100), tooltipSize: tooltipSize, in: bounds)
        XCTAssertEqual(origin, CGPoint(x: 366, y: 114))
    }

    func testFlipsTooltipAboveNearBottomEdge() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 100, y: 380), tooltipSize: tooltipSize, in: bounds)
        XCTAssertEqual(origin, CGPoint(x: 114, y: 286))
    }

    func testClampsOversizedTooltipToBoundsMargin() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 10, y: 10),
            tooltipSize: CGSize(width: 800, height: 500),
            in: bounds)
        XCTAssertEqual(origin, CGPoint(x: 8, y: 8))
    }

    func testTinyBoundsDoNotProduceAnInvertedPlacementArea() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 5, y: 4),
            tooltipSize: tooltipSize,
            in: CGRect(x: 0, y: 0, width: 10, height: 8))
        XCTAssertEqual(origin, CGPoint(x: 5, y: 4))
    }

    func testCustomGapWidensTheOffsetFromThePointer() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 100, y: 100), tooltipSize: tooltipSize, in: bounds, gap: 24)
        XCTAssertEqual(origin, CGPoint(x: 124, y: 124))
    }
}
