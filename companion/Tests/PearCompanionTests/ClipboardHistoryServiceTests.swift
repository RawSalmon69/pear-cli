import XCTest
@testable import PearCompanion

@MainActor
final class ClipboardHistoryServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ClipboardHistoryServiceTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func text(_ s: String) -> ClipItem {
        ClipItem(text: s, imageData: nil, thumbnail: nil, date: Date())
    }

    func testCountCapEvictsOldestUnpinnedOnly() {
        let service = ClipboardHistoryService(defaults: defaults)
        service.add(text("keep-me"))
        service.togglePin(service.items[0])
        for i in 0..<55 {
            service.add(text("item \(i)"))
        }
        XCTAssertEqual(service.items.filter { !$0.pinned }.count, 50)
        XCTAssertTrue(service.items.contains { $0.pinned && $0.text == "keep-me" })
    }

    func testClearKeepsPins() {
        let service = ClipboardHistoryService(defaults: defaults)
        service.add(text("pinned"))
        service.togglePin(service.items[0])
        service.add(text("ephemeral"))
        service.clear()
        XCTAssertEqual(service.items.map(\.text), ["pinned"])
    }

    func testPinnedTextPersistsAcrossReload() {
        let service = ClipboardHistoryService(defaults: defaults)
        service.add(text("sticky"))
        service.togglePin(service.items[0])
        service.add(text("loose"))

        let reloaded = ClipboardHistoryService(defaults: defaults)
        XCTAssertTrue(reloaded.items.contains { $0.pinned && $0.text == "sticky" })
        XCTAssertTrue(reloaded.items.contains { !$0.pinned && $0.text == "loose" })
    }

    func testDisplayFiltersCaseInsensitiveAndSortsPinsFirst() {
        let service = ClipboardHistoryService(defaults: defaults)
        service.add(text("Alpha Report"))
        service.add(text("beta notes"))
        service.add(text("alpha draft"))
        service.togglePin(service.items.first { $0.text == "Alpha Report" }!)

        let all = service.display(matching: "")
        XCTAssertEqual(all.first?.text, "Alpha Report") // pin sorts first

        let filtered = service.display(matching: "ALPHA")
        XCTAssertEqual(filtered.map(\.text), ["Alpha Report", "alpha draft"])
    }

    func testDuplicateOfNewestIsSkipped() {
        let service = ClipboardHistoryService(defaults: defaults)
        service.add(text("same"))
        service.add(text("same"))
        XCTAssertEqual(service.items.count, 1)
    }
}
