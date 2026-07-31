import CoreGraphics
import XCTest
@testable import PearCompanion

final class WindowZoneMathTests: XCTestCase {
    /// Even and odd widths/heights, a screen that starts left of and above the
    /// origin (a display placed to the left of the main one), and a screen that
    /// starts at a positive offset — the shapes that break naive rounding.
    private let screens = [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 0, y: 25, width: 1001, height: 763),
        CGRect(x: -1600, y: -200, width: 1599, height: 999),
        CGRect(x: 1512, y: 0, width: 2560, height: 1415),
    ]

    private func snap(_ zone: WindowZone, _ screen: CGRect) throws -> CGRect {
        try XCTUnwrap(WindowZoneMath.frame(
            for: .snap(zone), in: screen, current: .zero, lastFrame: nil))
    }

    // MARK: - Rounding

    func testEverySnapFrameIsIntegral() throws {
        for screen in screens {
            for zone in WindowZoneMath.zones {
                let frame = try snap(zone, screen)
                for value in [frame.minX, frame.minY, frame.width, frame.height] {
                    XCTAssertEqual(value, value.rounded(), "\(zone.id) on \(screen)")
                }
            }
        }
    }

    // MARK: - Tiling

    func testHalvesTileExactlyWithNoSeam() throws {
        for screen in screens {
            let left = try snap(WindowZoneMath.leftHalf, screen)
            let right = try snap(WindowZoneMath.rightHalf, screen)
            XCTAssertEqual(left.minX, screen.minX, "\(screen)")
            XCTAssertEqual(left.maxX, right.minX, "\(screen)")
            XCTAssertEqual(right.maxX, screen.maxX, "\(screen)")
            XCTAssertEqual(left.width + right.width, screen.width, "\(screen)")

            let top = try snap(WindowZoneMath.topHalf, screen)
            let bottom = try snap(WindowZoneMath.bottomHalf, screen)
            XCTAssertEqual(top.minY, screen.minY, "\(screen)")
            XCTAssertEqual(top.maxY, bottom.minY, "\(screen)")
            XCTAssertEqual(bottom.maxY, screen.maxY, "\(screen)")
            XCTAssertEqual(top.height + bottom.height, screen.height, "\(screen)")
        }
    }

    func testQuartersTileExactly() throws {
        for screen in screens {
            let topLeft = try snap(WindowZoneMath.topLeftQuarter, screen)
            let topRight = try snap(WindowZoneMath.topRightQuarter, screen)
            let bottomLeft = try snap(WindowZoneMath.bottomLeftQuarter, screen)
            let bottomRight = try snap(WindowZoneMath.bottomRightQuarter, screen)

            XCTAssertEqual(topLeft.maxX, topRight.minX, "\(screen)")
            XCTAssertEqual(bottomLeft.maxX, bottomRight.minX, "\(screen)")
            XCTAssertEqual(topLeft.maxY, bottomLeft.minY, "\(screen)")
            XCTAssertEqual(topRight.maxY, bottomRight.minY, "\(screen)")
            XCTAssertEqual(topLeft.minX, screen.minX, "\(screen)")
            XCTAssertEqual(topLeft.minY, screen.minY, "\(screen)")
            XCTAssertEqual(bottomRight.maxX, screen.maxX, "\(screen)")
            XCTAssertEqual(bottomRight.maxY, screen.maxY, "\(screen)")

            let area = [topLeft, topRight, bottomLeft, bottomRight]
                .reduce(0) { $0 + $1.width * $1.height }
            XCTAssertEqual(area, screen.width * screen.height, "\(screen)")
        }
    }

    func testThirdsTileExactly() throws {
        for screen in screens {
            let left = try snap(WindowZoneMath.leftThird, screen)
            let center = try snap(WindowZoneMath.centerThird, screen)
            let right = try snap(WindowZoneMath.rightThird, screen)
            XCTAssertEqual(left.minX, screen.minX, "\(screen)")
            XCTAssertEqual(left.maxX, center.minX, "\(screen)")
            XCTAssertEqual(center.maxX, right.minX, "\(screen)")
            XCTAssertEqual(right.maxX, screen.maxX, "\(screen)")
            XCTAssertEqual(left.width + center.width + right.width, screen.width, "\(screen)")
        }
    }

    func testTwoThirdsMeetTheOpposingThird() throws {
        for screen in screens {
            let leftTwo = try snap(WindowZoneMath.leftTwoThirds, screen)
            let right = try snap(WindowZoneMath.rightThird, screen)
            XCTAssertEqual(leftTwo.minX, screen.minX, "\(screen)")
            XCTAssertEqual(leftTwo.maxX, right.minX, "\(screen)")
            XCTAssertEqual(leftTwo.width + right.width, screen.width, "\(screen)")

            let rightTwo = try snap(WindowZoneMath.rightTwoThirds, screen)
            let left = try snap(WindowZoneMath.leftThird, screen)
            XCTAssertEqual(left.maxX, rightTwo.minX, "\(screen)")
            XCTAssertEqual(rightTwo.maxX, screen.maxX, "\(screen)")
            XCTAssertEqual(left.width + rightTwo.width, screen.width, "\(screen)")
        }
    }

    func testMaximizeCoversTheWholeVisibleFrame() throws {
        for screen in screens {
            XCTAssertEqual(try snap(WindowZoneMath.maximize, screen), screen, "\(screen)")
        }
    }

    // MARK: - Centre

    func testCenterKeepsTheSizeAndCentresIt() {
        let screen = CGRect(x: 0, y: 25, width: 1001, height: 763)
        let current = CGRect(x: 900, y: 700, width: 400, height: 300)
        let frame = WindowZoneMath.frame(for: .center, in: screen, current: current, lastFrame: nil)
        XCTAssertEqual(frame, CGRect(x: 301, y: 257, width: 400, height: 300))
        XCTAssertEqual(frame?.size, current.size)
    }

    func testCenterOnAnOffsetScreenStaysOnThatScreen() {
        let screen = CGRect(x: -1600, y: -200, width: 1599, height: 999)
        let current = CGRect(x: 0, y: 0, width: 600, height: 400)
        let frame = WindowZoneMath.frame(for: .center, in: screen, current: current, lastFrame: nil)
        XCTAssertEqual(frame, CGRect(x: -1101, y: 100, width: 600, height: 400))
    }

    func testCenterClampsAWindowLargerThanTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let oversized = CGRect(x: 40, y: 40, width: 1600, height: 1200)
        let frame = WindowZoneMath.frame(for: .center, in: screen, current: oversized, lastFrame: nil)
        // Origin pinned to the visible frame, size untouched: a negative offset
        // would put the title bar out of reach.
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1600, height: 1200))
    }

    func testCenterClampsAgainstTheOffsetScreensOrigin() {
        let screen = CGRect(x: -1600, y: -200, width: 1599, height: 999)
        let oversized = CGRect(x: 0, y: 0, width: 2000, height: 1400)
        let frame = WindowZoneMath.frame(for: .center, in: screen, current: oversized, lastFrame: nil)
        XCTAssertEqual(frame, CGRect(x: -1600, y: -200, width: 2000, height: 1400))
    }

    // MARK: - Restore

    func testRestoreReturnsTheRememberedFrameRoundedToPixels() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let last = CGRect(x: 10.4, y: 20.6, width: 300.5, height: 200.5)
        let frame = WindowZoneMath.frame(for: .restore, in: screen, current: .zero, lastFrame: last)
        XCTAssertEqual(frame, CGRect(x: 10, y: 21, width: 301, height: 201))
    }

    func testRestoreWithoutARememberedFrameDoesNothing() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertNil(WindowZoneMath.frame(
            for: .restore, in: screen, current: CGRect(x: 1, y: 2, width: 3, height: 4),
            lastFrame: nil))
    }

    // MARK: - Catalogue

    func testCatalogueIdsAreUniqueAndResolvable() {
        let ids = WindowZoneMath.zones.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for zone in WindowZoneMath.zones {
            XCTAssertEqual(WindowZoneMath.zone(id: zone.id), zone)
            XCTAssertFalse(zone.name.isEmpty, zone.id)
        }
        XCTAssertNil(WindowZoneMath.zone(id: "zone-we-never-shipped"))
    }

    func testCatalogueIdsDoNotShadowTheReservedActionTokens() {
        let ids = Set(WindowZoneMath.zones.map(\.id))
        XCTAssertFalse(ids.contains("center"))
        XCTAssertFalse(ids.contains("restore"))
    }

    func testEveryUnitRectStaysInsideTheVisibleFrame() {
        for zone in WindowZoneMath.zones {
            XCTAssertGreaterThanOrEqual(zone.unit.minX, 0, zone.id)
            XCTAssertGreaterThanOrEqual(zone.unit.minY, 0, zone.id)
            XCTAssertLessThanOrEqual(zone.unit.maxX, 1, zone.id)
            XCTAssertLessThanOrEqual(zone.unit.maxY, 1, zone.id)
        }
    }
}
