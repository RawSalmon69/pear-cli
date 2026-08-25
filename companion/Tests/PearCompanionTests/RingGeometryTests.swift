import CoreGraphics
import XCTest

@testable import PearCompanion

/// The ring's hit test: dead zone, hub, and eight sectors, all measured from the
/// centre in view space (y-down). The boundaries are the point of these tests —
/// a sector edge that both neighbours claim, or that neither does, is a window
/// flung somewhere the user did not aim.
final class RingGeometryTests: XCTestCase {
    /// A point `distance` from the centre on a bearing `degrees` clockwise from
    /// 12 o'clock, in the y-down space `slot(atOffset:)` expects.
    private func offset(_ degrees: CGFloat, _ distance: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: distance * sin(radians), y: -distance * cos(radians))
    }

    private func slot(_ degrees: CGFloat, _ distance: CGFloat) -> RingSlot? {
        RingGeometry.slot(atOffset: offset(degrees, distance))
    }

    /// Mid-band: comfortably inside the sectors on every bearing.
    private let band: CGFloat = 95

    // MARK: - Slot order

    /// The ring takes its order from `RingSlot`'s declaration rather than a
    /// table of its own, so this is the assertion that catches a reordered or
    /// added case rotating the whole ring.
    func testCompassIsTheEightSlotsClockwiseFromTop() {
        XCTAssertEqual(RingGeometry.compass, [
            .top, .topTrailing, .trailing, .bottomTrailing,
            .bottom, .bottomLeading, .leading, .topLeading,
        ])
        XCTAssertFalse(RingGeometry.compass.contains(.hub))
        XCTAssertEqual(RingGeometry.compass.count + 1, RingSlot.allCases.count)
    }

    // MARK: - Bearings

    func testEachCompassBearingLandsOnItsOwnSlot() {
        for (index, expected) in RingGeometry.compass.enumerated() {
            let bearing = CGFloat(index) * 45
            XCTAssertEqual(slot(bearing, band), expected, "\(bearing)°")
            // Same bearing expressed a turn later — the caller may hand us any
            // angle, so normalisation has to hold.
            XCTAssertEqual(slot(bearing + 360, band), expected, "\(bearing)° + 360")
            XCTAssertEqual(slot(bearing - 360, band), expected, "\(bearing)° - 360")
        }
    }

    func testCardinalBearingsAreNotMirroredOrRotated() {
        // Spelled out rather than derived, so a sign flip in the y-down
        // conversion cannot pass by agreeing with itself.
        XCTAssertEqual(RingGeometry.slot(atOffset: CGPoint(x: 0, y: -band)), .top)
        XCTAssertEqual(RingGeometry.slot(atOffset: CGPoint(x: band, y: 0)), .trailing)
        XCTAssertEqual(RingGeometry.slot(atOffset: CGPoint(x: 0, y: band)), .bottom)
        XCTAssertEqual(RingGeometry.slot(atOffset: CGPoint(x: -band, y: 0)), .leading)
        // Diagonals: +x is trailing and +y is *down*, so this quadrant is
        // bottom-trailing.
        XCTAssertEqual(RingGeometry.slot(atOffset: CGPoint(x: 60, y: 60)), .bottomTrailing)
        XCTAssertEqual(RingGeometry.slot(atOffset: CGPoint(x: -60, y: -60)), .topLeading)
    }

    // MARK: - Sector boundaries

    /// Every edge sits at 22.5° + k·45°, and the switch happens *at* the edge to
    /// within a millionth of a degree.
    ///
    /// The implementation breaks an exact tie toward the clockwise-later sector,
    /// but a bearing built from `sin`/`cos` cannot land on an edge exactly — the
    /// round trip through `atan2` misses by a few ULPs, which is how 202.5° came
    /// out as the earlier sector while its seven siblings came out as the later
    /// one. So the assertion is where the transition is, not which side of it an
    /// unreachable exact edge falls on. Nothing a pointer can produce sits
    /// closer to an edge than this.
    func testSectorBoundariesAreExactlyWhereTheyShouldBe() {
        for index in 0..<RingGeometry.compass.count {
            let edge = 22.5 + CGFloat(index) * 45
            let earlier = RingGeometry.compass[index]
            let later = RingGeometry.compass[(index + 1) % RingGeometry.compass.count]

            for epsilon: CGFloat in [0.01, 1e-6] {
                XCTAssertEqual(slot(edge - epsilon, band), earlier, "\(edge)° - \(epsilon)")
                XCTAssertEqual(slot(edge + epsilon, band), later, "\(edge)° + \(epsilon)")
            }
        }
    }

    /// The wrap-around edge, the one an off-by-one lands on: 337.5° closes
    /// top-leading and opens top.
    func testTheWrapAroundBoundaryClosesTheRing() {
        XCTAssertEqual(slot(337.5 - 1e-6, band), .topLeading)
        XCTAssertEqual(slot(337.5 + 1e-6, band), .top)
        XCTAssertEqual(slot(359.9, band), .top)
        XCTAssertEqual(slot(0, band), .top)
    }

    /// A sweep at 1/10° steps: every bearing selects something, and the slot
    /// changes exactly eight times around the circle. Catches both a gap and an
    /// overlap without naming either.
    func testASweepCoversTheCircleWithExactlyEightSectors() {
        var previous = slot(0, band)
        var changes = 0
        var step: CGFloat = 0.1
        while step < 360 {
            guard let current = slot(step, band) else {
                return XCTFail("no slot at \(step)°")
            }
            if current != previous { changes += 1 }
            previous = current
            step += 0.1
        }
        XCTAssertEqual(changes, 8)
    }

    // MARK: - Dead zone

    func testTheDeadZoneSelectsNothing() {
        XCTAssertNil(RingGeometry.slot(atOffset: .zero))
        for bearing in stride(from: CGFloat(0), to: 360, by: 15) {
            XCTAssertNil(slot(bearing, 0.5), "\(bearing)°")
            XCTAssertNil(slot(bearing, RingGeometry.deadZone - 0.01), "\(bearing)°")
        }
    }

    /// The dead zone is half-open: its own radius is already the hub. A wobble
    /// inside it selects nothing, one deliberate nudge out of it does.
    func testTheDeadZoneEdgeBelongsToTheHub() {
        XCTAssertNil(slot(0, RingGeometry.deadZone - 0.01))
        XCTAssertEqual(slot(0, RingGeometry.deadZone), .hub)
        XCTAssertEqual(slot(180, RingGeometry.deadZone), .hub)
    }

    // MARK: - Hub

    func testTheHubOwnsItsWholeBandOnEveryBearing() {
        let inside = (RingGeometry.deadZone + RingGeometry.hubRadius) / 2
        for bearing in stride(from: CGFloat(0), to: 360, by: 5) {
            XCTAssertEqual(slot(bearing, inside), .hub, "\(bearing)°")
        }
    }

    func testTheHubEdgeBelongsToTheSectors() {
        XCTAssertEqual(slot(0, RingGeometry.hubRadius - 0.01), .hub)
        XCTAssertEqual(slot(0, RingGeometry.hubRadius), .top)
        XCTAssertEqual(slot(90, RingGeometry.hubRadius), .trailing)
    }

    // MARK: - Outer edge

    /// Past the rim is nothing, not the nearest sector: flicking clear of the
    /// ring is how the gesture is backed out of.
    func testOutsideTheRingSelectsNothing() {
        for bearing in stride(from: CGFloat(0), to: 360, by: 15) {
            XCTAssertNotNil(slot(bearing, RingGeometry.outerRadius - 0.01), "\(bearing)°")
            XCTAssertNil(slot(bearing, RingGeometry.outerRadius), "\(bearing)°")
            XCTAssertNil(slot(bearing, RingGeometry.outerRadius + 1), "\(bearing)°")
            XCTAssertNil(slot(bearing, 4000), "\(bearing)°")
        }
    }

    // MARK: - Radii

    func testRadiiAreOrderedAndThePanelIsTheDisc() {
        XCTAssertLessThan(RingGeometry.deadZone, RingGeometry.hubRadius)
        XCTAssertLessThan(RingGeometry.hubRadius, RingGeometry.outerRadius)
        XCTAssertEqual(RingGeometry.side, RingGeometry.outerRadius * 2)
    }

    // MARK: - Drawn shapes

    /// The wedges are drawn in a y-up layer space while the hit test works in
    /// y-down view space, which is exactly where a mirrored or quarter-turned
    /// ring comes from. So walk the whole circle: take the slot the hit test
    /// names, flip the same point into layer space, and require that no other
    /// slot's wedge contains it — and that its own does, everywhere except the
    /// trimmed hairlines between wedges.
    func testTheDrawnWedgesAgreeWithTheHitTestAllTheWayRound() throws {
        let center = CGPoint(x: RingGeometry.outerRadius, y: RingGeometry.outerRadius)
        let paths = try RingGeometry.compass.map {
            try XCTUnwrap(RingGeometry.wedgePath(for: $0, center: center))
        }
        let radius = RingGeometry.labelRadius
        var covered = 0

        for degrees in stride(from: CGFloat(0), to: 360, by: 0.25) {
            let radians = degrees * .pi / 180
            let expected = try XCTUnwrap(slot(degrees, radius), "\(degrees)°")
            // Same bearing, y-up: +y is now up, so cos is the vertical part.
            let inLayer = CGPoint(
                x: center.x + radius * sin(radians),
                y: center.y + radius * cos(radians))

            let owners = RingGeometry.compass.indices.filter { paths[$0].contains(inLayer) }
            XCTAssertLessThanOrEqual(owners.count, 1, "\(degrees)° is in \(owners.count) wedges")
            if let owner = owners.first {
                XCTAssertEqual(RingGeometry.compass[owner], expected, "\(degrees)°")
                covered += 1
            }
        }

        // What is left uncovered is exactly the trimmed hairlines between
        // wedges — two per 45° sector. Pinning the fraction rather than a floor
        // means widening the trim into a visible gap fails here too.
        let trimmed = (RingGeometry.sectorWidth - 2 * RingGeometry.wedgeTrim)
            / RingGeometry.sectorWidth
        XCTAssertEqual(Double(covered) / (360 / 0.25), Double(trimmed), accuracy: 0.01)
    }

    /// The plain-language version of the test above, in case a future reader
    /// wants one assertion they can hold in their head: up is up.
    func testTheTopWedgeIsDrawnAtTheTop() throws {
        let center = CGPoint(x: 500, y: 500)
        let above = CGPoint(x: 500, y: 500 + RingGeometry.labelRadius)
        let below = CGPoint(x: 500, y: 500 - RingGeometry.labelRadius)
        let top = try XCTUnwrap(RingGeometry.wedgePath(for: .top, center: center))
        XCTAssertTrue(top.contains(above))
        XCTAssertFalse(top.contains(below))
        XCTAssertTrue(try XCTUnwrap(RingGeometry.wedgePath(for: .bottom, center: center))
            .contains(below))
    }

    /// A label has to sit in its own wedge, or the ring names the wrong sector.
    func testEveryLabelSitsInsideItsOwnWedge() throws {
        let center = CGPoint(x: 140, y: 90)
        for slot in RingGeometry.compass {
            let path = try XCTUnwrap(RingGeometry.wedgePath(for: slot, center: center))
            XCTAssertTrue(
                path.contains(RingGeometry.labelPoint(for: slot, center: center)), slot.rawValue)
        }
        // The hub labels itself in the middle.
        XCTAssertEqual(RingGeometry.labelPoint(for: .hub, center: center), center)
        XCTAssertTrue(RingGeometry.hubPath(center: center).contains(center))
    }

    /// Compass bearings, spelled out in layer space: a sign error in the y-up
    /// conversion moves a label to the opposite side of the ring.
    func testLabelPointsPointTheWayTheyAreNamed() {
        let center = CGPoint(x: 0, y: 0)
        let radius = RingGeometry.labelRadius
        XCTAssertEqual(RingGeometry.labelPoint(for: .top, center: center).y, radius, accuracy: 1e-9)
        XCTAssertEqual(
            RingGeometry.labelPoint(for: .bottom, center: center).y, -radius, accuracy: 1e-9)
        XCTAssertEqual(
            RingGeometry.labelPoint(for: .trailing, center: center).x, radius, accuracy: 1e-9)
        XCTAssertEqual(
            RingGeometry.labelPoint(for: .leading, center: center).x, -radius, accuracy: 1e-9)
    }

    /// The drawn shapes nest inside the hit-test radii, with the moat between
    /// the hub disc and the band falling either side of the hub boundary.
    func testDrawnRadiiNestInsideTheHitTestRadii() {
        XCTAssertLessThan(RingGeometry.hubDiscRadius, RingGeometry.hubRadius)
        XCTAssertLessThan(RingGeometry.hubRadius, RingGeometry.bandInner)
        XCTAssertLessThan(RingGeometry.bandInner, RingGeometry.labelRadius)
        XCTAssertLessThan(RingGeometry.labelRadius, RingGeometry.bandOuter)
        XCTAssertLessThan(RingGeometry.bandOuter, RingGeometry.rimRadius)
        XCTAssertLessThan(RingGeometry.rimRadius, RingGeometry.outerRadius)
        // The dead zone stays inside the hub disc, so the "nothing selected"
        // patch is never larger than the target drawn around it.
        XCTAssertLessThan(RingGeometry.deadZone, RingGeometry.hubDiscRadius)
    }

    // MARK: - Wedge angles

    /// The drawing takes its wedge angles from `centerAngle(of:)`, so a wedge
    /// painted on one bearing while the hit test answers another would be a
    /// ring that lies. Every centre angle must hit-test back to its own slot.
    func testEveryWedgeCentreHitTestsBackToItsOwnSlot() throws {
        for expected in RingGeometry.compass {
            let angle = try XCTUnwrap(RingGeometry.centerAngle(of: expected))
            let point = CGPoint(x: band * sin(angle), y: -band * cos(angle))
            XCTAssertEqual(RingGeometry.slot(atOffset: point), expected)
        }
        XCTAssertNil(RingGeometry.centerAngle(of: .hub))
    }

    func testWedgesTileTheFullCircleWithNoOverlap() {
        let angles = RingGeometry.compass.compactMap { RingGeometry.centerAngle(of: $0) }
        XCTAssertEqual(angles.count, 8)
        XCTAssertEqual(angles.first, 0)
        for (index, angle) in angles.enumerated() {
            XCTAssertEqual(angle, CGFloat(index) * RingGeometry.sectorWidth, accuracy: 1e-9)
        }
        XCTAssertEqual(
            RingGeometry.sectorWidth * CGFloat(angles.count), 2 * .pi, accuracy: 1e-9)
    }

    // MARK: - Labels

    func testLabelsComeFromTheZoneItself() {
        XCTAssertEqual(
            RingLabel.text(for: .snap(WindowZoneMath.leftHalf)), WindowZoneMath.leftHalf.name)
        XCTAssertEqual(
            RingLabel.text(for: .snap(WindowZoneMath.maximize)), WindowZoneMath.maximize.name)
        XCTAssertEqual(RingLabel.text(for: .center), "Center")
        XCTAssertEqual(RingLabel.text(for: .restore), "Restore")
    }

    /// A cleared slot reads as empty, which is what tells the ring to draw it
    /// quiet and unlabelled instead of leaving a wedge that looks broken.
    func testAClearedSlotHasNoLabel() {
        XCTAssertEqual(RingLabel.text(for: nil), "")
    }

    func testEveryDefaultRingSlotHasSomethingToRead() {
        for slot in RingSlot.allCases {
            let label = RingLabel.text(for: WindowSettings.ringDefaults[slot])
            XCTAssertFalse(label.isEmpty, slot.rawValue)
        }
    }
}
