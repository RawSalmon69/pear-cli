import XCTest
@testable import PearCompanion

/// Pure tree-prune math behind the in-place delete recovery: removing a
/// just-trashed node must drop it and shrink every ancestor by exactly its
/// size, with no disk access. Pins the mechanism that replaced the full,
/// chart-dimming home rescan after a delete.
final class DiskTreePruneTests: XCTestCase {
    /// root(100) ├ a(60) │  ├ a1(40)
    ///                    │  └ a2(20)
    ///           └ b(30) └ b1(30)
    /// (root own size = 100 - 60 - 30 = 10)
    private func tree() -> DiskNode {
        let a1 = DiskNode(id: "/r/a/a1", name: "a1", size: 40, isDirectory: false, children: [])
        let a2 = DiskNode(id: "/r/a/a2", name: "a2", size: 20, isDirectory: false, children: [])
        let a = DiskNode(id: "/r/a", name: "a", size: 60, isDirectory: true, children: [a1, a2])
        let b1 = DiskNode(id: "/r/b/b1", name: "b1", size: 30, isDirectory: false, children: [])
        let b = DiskNode(id: "/r/b", name: "b", size: 30, isDirectory: true, children: [b1])
        return DiskNode(id: "/r", name: "r", size: 100, isDirectory: true, children: [a, b])
    }

    func testRemovingTopLevelChildDropsItAndShrinksRoot() throws {
        let pruned = try XCTUnwrap(tree().removingDescendant(id: "/r/a"))
        XCTAssertEqual(pruned.size, 40, "root shrinks by a's 60")
        XCTAssertEqual(pruned.children.map(\.id), ["/r/b"], "a is gone, b remains")
    }

    func testRemovingNestedLeafShrinksEveryAncestor() throws {
        let pruned = try XCTUnwrap(tree().removingDescendant(id: "/r/a/a1"))
        XCTAssertEqual(pruned.size, 60, "root shrinks by a1's 40")
        let a = try XCTUnwrap(pruned.firstDescendant(id: "/r/a"))
        XCTAssertEqual(a.size, 20, "a shrinks by a1's 40")
        XCTAssertEqual(a.children.map(\.id), ["/r/a/a2"], "a1 removed, a2 kept")
        XCTAssertNil(pruned.firstDescendant(id: "/r/a/a1"), "the pruned node is gone")
    }

    func testRemovingUnknownIDIsANoOp() {
        XCTAssertNil(tree().removingDescendant(id: "/r/nope"), "an unknown id returns nil")
        XCTAssertNil(tree().removingDescendant(id: "/r"), "the receiver itself is never removed")
    }

    func testSizeNeverGoesNegative() throws {
        // A child whose recorded size exceeds the parent's must still clamp to 0.
        let big = DiskNode(id: "/r/big", name: "big", size: 500, isDirectory: false, children: [])
        let root = DiskNode(id: "/r", name: "r", size: 100, isDirectory: true, children: [big])
        let pruned = try XCTUnwrap(root.removingDescendant(id: "/r/big"))
        XCTAssertEqual(pruned.size, 0, "clamped, never negative")
    }
}
