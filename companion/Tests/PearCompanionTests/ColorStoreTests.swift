import SwiftUI
import XCTest
@testable import PearCompanion

@MainActor
final class ColorStoreTests: XCTestCase {
    // MARK: - PickedColor formats

    func testHexRoundTrip() throws {
        let color = try XCTUnwrap(PickedColor(hex: "#3A7BD5"))
        XCTAssertEqual(color.hexString, "#3A7BD5")
    }

    /// The custom-accent picker persists a SwiftUI `Color` as `PickedColor`
    /// hex and rebuilds it on launch; that bridge must preserve sRGB
    /// components so the accent survives a relaunch unchanged.
    func testCustomAccentColorRoundTripsThroughHex() throws {
        let chosen = Color(red: 0.24, green: 0.62, blue: 0.31)
        let hex = try XCTUnwrap(PickedColor(sampled: NSColor(chosen))?.hexString)
        XCTAssertEqual(hex, "#3D9E4F")

        let restored = try XCTUnwrap(PickedColor(hex: hex)).swiftUIColor
        XCTAssertEqual(PickedColor(sampled: NSColor(restored))?.hexString, hex)
    }

    func testHexAcceptsBareStringWithoutHash() throws {
        let color = try XCTUnwrap(PickedColor(hex: "FF00AA"))
        XCTAssertEqual(color.hexString, "#FF00AA")
    }

    func testHexRejectsMalformedInput() {
        XCTAssertNil(PickedColor(hex: "not-a-color"))
        XCTAssertNil(PickedColor(hex: "#ABC"))
    }

    func testRGBString() {
        let color = PickedColor(red: 1, green: 0, blue: 0.5)
        XCTAssertEqual(color.rgbString, "rgb(255, 0, 128)")
    }

    func testHSLStringForPrimaryRed() {
        let color = PickedColor(red: 1, green: 0, blue: 0)
        XCTAssertEqual(color.hslString, "hsl(0, 100%, 50%)")
    }

    func testHSLStringForWhiteAndBlack() {
        XCTAssertEqual(PickedColor.white.hslString, "hsl(0, 0%, 100%)")
        XCTAssertEqual(PickedColor.black.hslString, "hsl(0, 0%, 0%)")
    }

    func testSwiftUILiteralFormat() {
        let color = PickedColor(red: 0.25, green: 0.5, blue: 0.75)
        XCTAssertEqual(color.swiftUIString, "Color(red: 0.250, green: 0.500, blue: 0.750)")
    }

    // MARK: - Contrast

    func testContrastRatioBlackOnWhiteIs21() {
        let ratio = PickedColor.black.contrast(against: .white).ratio
        XCTAssertEqual(ratio, 21.0, accuracy: 0.001)
    }

    func testContrastRatioSameColorIs1() {
        let color = PickedColor(red: 0.4, green: 0.4, blue: 0.4)
        XCTAssertEqual(color.contrast(against: color).ratio, 1.0, accuracy: 0.001)
    }

    func testContrastBadgesForBlackOnWhite() {
        let result = PickedColor.black.contrast(against: .white)
        XCTAssertTrue(result.passesAA)
        XCTAssertTrue(result.passesAAA)
    }

    func testContrastBadgesFailForLowContrast() {
        // Two close mid-grays: well under both AA and AAA thresholds.
        let a = PickedColor(red: 0.5, green: 0.5, blue: 0.5)
        let b = PickedColor(red: 0.55, green: 0.55, blue: 0.55)
        let result = a.contrast(against: b)
        XCTAssertFalse(result.passesAA)
        XCTAssertFalse(result.passesAAA)
    }

    // MARK: - Store history

    private func makeStore(suite: String) throws -> (ColorStore, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (ColorStore(defaults: defaults, historyKey: "history"), defaults)
    }

    func testAddSetsCurrentAndHistory() throws {
        let (store, defaults) = try makeStore(suite: "ColorStoreTests-add")
        defer { defaults.removePersistentDomain(forName: "ColorStoreTests-add") }

        let color = try XCTUnwrap(PickedColor(hex: "#112233"))
        store.add(color)

        XCTAssertEqual(store.current?.hexString, "#112233")
        XCTAssertEqual(store.history.map(\.hexString), ["#112233"])
    }

    func testHistoryCapsAtEightMostRecentFirst() throws {
        let (store, defaults) = try makeStore(suite: "ColorStoreTests-cap")
        defer { defaults.removePersistentDomain(forName: "ColorStoreTests-cap") }

        for i in 0..<10 {
            let hex = String(format: "#%02X%02X%02X", i, i, i)
            store.add(try XCTUnwrap(PickedColor(hex: hex)))
        }

        XCTAssertEqual(store.history.count, 8)
        // Most recently added (#090909) first, oldest two (#000000, #010101) dropped.
        XCTAssertEqual(store.history.first?.hexString, "#090909")
        XCTAssertEqual(store.history.last?.hexString, "#020202")
        XCTAssertFalse(store.history.map(\.hexString).contains("#000000"))
        XCTAssertFalse(store.history.map(\.hexString).contains("#010101"))
    }

    func testAddingDuplicateHexMovesToFrontWithoutDuplicating() throws {
        let (store, defaults) = try makeStore(suite: "ColorStoreTests-dedup")
        defer { defaults.removePersistentDomain(forName: "ColorStoreTests-dedup") }

        let red = try XCTUnwrap(PickedColor(hex: "#FF0000"))
        let blue = try XCTUnwrap(PickedColor(hex: "#0000FF"))
        store.add(red)
        store.add(blue)
        store.add(red)

        XCTAssertEqual(store.history.map(\.hexString), ["#FF0000", "#0000FF"])
    }

    func testSelectChangesCurrentWithoutReorderingHistory() throws {
        let (store, defaults) = try makeStore(suite: "ColorStoreTests-select")
        defer { defaults.removePersistentDomain(forName: "ColorStoreTests-select") }

        let red = try XCTUnwrap(PickedColor(hex: "#FF0000"))
        let blue = try XCTUnwrap(PickedColor(hex: "#0000FF"))
        store.add(red)
        store.add(blue)
        XCTAssertEqual(store.current?.hexString, "#0000FF")

        store.select(red)

        XCTAssertEqual(store.current?.hexString, "#FF0000")
        // History order is untouched by select — blue stays on top since it
        // was added last; only `current` changes.
        XCTAssertEqual(store.history.map(\.hexString), ["#0000FF", "#FF0000"])
    }

    func testRemoveDropsHistoryEntryButKeepsCurrent() throws {
        let (store, defaults) = try makeStore(suite: "ColorStoreTests-remove")
        defer { defaults.removePersistentDomain(forName: "ColorStoreTests-remove") }

        let red = try XCTUnwrap(PickedColor(hex: "#FF0000"))
        let blue = try XCTUnwrap(PickedColor(hex: "#0000FF"))
        store.add(red)
        store.add(blue)

        store.remove(red)

        XCTAssertEqual(store.history.map(\.hexString), ["#0000FF"])
        XCTAssertEqual(store.current?.hexString, "#0000FF")
    }

    func testHistoryPersistsAcrossReload() throws {
        let suite = "ColorStoreTests-persist"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ColorStore(defaults: defaults, historyKey: "history")
        store.add(try XCTUnwrap(PickedColor(hex: "#ABCDEF")))
        store.add(try XCTUnwrap(PickedColor(hex: "#123456")))

        let reloaded = ColorStore(defaults: defaults, historyKey: "history")
        XCTAssertEqual(reloaded.history.map(\.hexString), ["#123456", "#ABCDEF"])
        XCTAssertEqual(reloaded.current?.hexString, "#123456")
    }
}
