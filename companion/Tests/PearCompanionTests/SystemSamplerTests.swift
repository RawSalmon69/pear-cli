import XCTest

@testable import PearCompanion

/// The CPU delta math outlived the Monitor tool: RunCat's animation speed and
/// the panel greeting's health line both still run on it.
final class SystemSamplerTests: XCTestCase {
    func testCoreUsagesTwoCores() {
        // core0: user +50, system +20, idle +180, nice +0 -> 70 / 250 = 0.28
        // core1: user  +0, system  +0, idle +100, nice +0 ->  0 / 100 = 0.0
        let prev: [UInt32] = [100, 50, 800, 0, /* core1 */ 10, 10, 80, 0]
        let curr: [UInt32] = [150, 70, 980, 0, /* core1 */ 10, 10, 180, 0]

        let usages = CPUUsage.coreUsages(previous: prev, current: curr)
        XCTAssertEqual(usages.count, 2)
        XCTAssertEqual(usages[0], 0.28, accuracy: 0.0001)
        XCTAssertEqual(usages[1], 0.0, accuracy: 0.0001)
    }

    func testCoreUsageFullyBusy() {
        let prev: [UInt32] = [0, 0, 0, 0]
        let curr: [UInt32] = [100, 0, 0, 0]  // all busy, zero idle
        let usages = CPUUsage.coreUsages(previous: prev, current: curr)
        XCTAssertEqual(usages, [1.0])
    }

    func testCoreUsageHandlesCounterWrap() {
        // user wraps from max-9 to 10 -> real delta 20; idle +80 -> 20/100.
        let prev: [UInt32] = [UInt32.max - 9, 0, 1000, 0]
        let curr: [UInt32] = [10, 0, 1080, 0]
        let usages = CPUUsage.coreUsages(previous: prev, current: curr)
        XCTAssertEqual(usages.count, 1)
        XCTAssertEqual(usages[0], 0.2, accuracy: 0.0001)
    }

    func testCoreUsageAllIdle() {
        let prev: [UInt32] = [5, 5, 100, 0]
        let curr: [UInt32] = [5, 5, 300, 0]
        XCTAssertEqual(CPUUsage.coreUsages(previous: prev, current: curr), [0.0])
    }

    func testCoreUsageZeroTotal() {
        let same: [UInt32] = [7, 7, 7, 7]
        XCTAssertEqual(CPUUsage.coreUsages(previous: same, current: same), [0.0])
    }

    func testCoreUsagesRejectsMismatchedOrRaggedInput() {
        XCTAssertTrue(CPUUsage.coreUsages(previous: [1, 2, 3, 4], current: [1, 2, 3]).isEmpty)
        XCTAssertTrue(CPUUsage.coreUsages(previous: [1, 2, 3], current: [1, 2, 3]).isEmpty)
        XCTAssertTrue(CPUUsage.coreUsages(previous: [], current: []).isEmpty)
    }
}
