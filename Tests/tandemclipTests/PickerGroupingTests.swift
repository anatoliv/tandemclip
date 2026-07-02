import XCTest
@testable import tandemclip

final class PickerGroupingTests: XCTestCase {
    private func makeModel() -> PickerModel {
        PickerModel(onPickHistory: { _ in }, onPullPeer: { _ in }, onDropFiles: { _ in },
                    onDeleteHistory: { _ in }, onClose: {})
    }

    private func item(_ text: String, source: String, file: Bool = false) -> HistoryItem {
        let snap = file
            ? ClipSnapshot(parts: [:], files: [ClipFile(name: text, data: Data(text.utf8))])
            : ClipSnapshot(parts: [.text: Data(text.utf8)])
        return HistoryItem(snapshot: snap, hash: snap.hash, timestamp: 0, label: text, source: source)
    }

    private func load(_ model: PickerModel, _ items: [HistoryItem]) {
        model.reload(history: items, peers: [], showCount: 50, clipUsage: "")
    }

    func testGroupBadgesCountByKind() {
        let model = makeModel()
        load(model, [item("a", source: "Home"), item("b", source: "Home"),
                     item("f.txt", source: "Home", file: true), item("c", source: "HCL")])

        let groups = model.grouped
        XCTAssertEqual(groups.map(\.source), ["Home", "HCL"])
        XCTAssertEqual(groups[0].badges.map { "\($0.symbol):\($0.count)" }, ["textformat:2", "doc:1"])
        XCTAssertEqual(groups[1].badges.map { "\($0.symbol):\($0.count)" }, ["textformat:1"])
    }

    func testCollapseHidesRowsKeepsHeaderAndReindexes() {
        let model = makeModel()
        load(model, [item("a", source: "Home"), item("b", source: "Home"), item("c", source: "HCL")])
        XCTAssertEqual(model.filtered.count, 3)

        model.toggleGroup("Home")
        // Rows gone from the visible list, header (with badges) still present.
        XCTAssertEqual(model.filtered.map(\.label), ["c"])
        let groups = model.grouped
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups[0].isCollapsed)
        XCTAssertTrue(groups[0].entries.isEmpty)
        XCTAssertEqual(groups[0].badges.first?.count, 2)
        // Remaining visible rows re-index from 0 so ⌘1–9/selection match the screen.
        XCTAssertEqual(groups[1].entries.map(\.index), [0])

        model.toggleGroup("Home")
        XCTAssertEqual(model.filtered.count, 3)
        XCTAssertEqual(model.grouped[0].entries.map(\.index), [0, 1])
    }

    func testCollapseClampsSelection() {
        let model = makeModel()
        load(model, [item("a", source: "Home"), item("b", source: "Home"), item("c", source: "HCL")])
        model.selection = 2
        model.toggleGroup("Home")   // only 1 visible row remains
        XCTAssertEqual(model.selection, 0)
    }

    func testCollapseChangeCallbackFiresForPersistence() {
        let model = makeModel()
        load(model, [item("a", source: "Home")])
        var saved: Set<String>?
        model.onCollapsedChange = { saved = $0 }
        model.toggleGroup("Home")
        XCTAssertEqual(saved, ["Home"])
        model.toggleGroup("Home")
        XCTAssertEqual(saved, [])
    }

    func testBadgesRespectActiveKindFilter() {
        let model = makeModel()
        load(model, [item("a", source: "Home"), item("f.txt", source: "Home", file: true)])
        model.kindFilter = .file
        XCTAssertEqual(model.grouped[0].badges.map { "\($0.symbol):\($0.count)" }, ["doc:1"])
    }
}
