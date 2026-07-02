import XCTest
@testable import tandemclip

final class PickerGroupingTests: XCTestCase {
    private func makeModel() -> PickerModel {
        PickerModel(onPickHistory: { _ in }, onPullPeer: { _ in }, onDropFiles: { _ in },
                    onDeleteHistory: { _ in }, onClose: {})
    }

    private func item(_ text: String, source: String, file: Bool = false, rich: Bool = false) -> HistoryItem {
        let snap: ClipSnapshot
        if file {
            snap = ClipSnapshot(parts: [:], files: [ClipFile(name: text, data: Data(text.utf8))])
        } else if rich {
            snap = ClipSnapshot(parts: [.text: Data(text.utf8), .rtf: Data("{\\rtf1}".utf8)])
        } else {
            snap = ClipSnapshot(parts: [.text: Data(text.utf8)])
        }
        return HistoryItem(snapshot: snap, hash: snap.hash, timestamp: 0, label: text, source: source)
    }

    private func load(_ model: PickerModel, _ items: [HistoryItem]) {
        model.reload(history: items, peers: [], showCount: 50, clipUsage: "")
    }

    func testGroupBadgesCountByKind() {
        let model = makeModel()
        load(model, [item("a", source: "Home"), item("b", source: "Home"),
                     item("styled", source: "Home", rich: true),
                     item("f.txt", source: "Home", file: true), item("c", source: "HCL")])

        let groups = model.grouped
        XCTAssertEqual(groups.map(\.source), ["Home", "HCL"])
        // Plain and rich text count separately.
        XCTAssertEqual(groups[0].badges.map { "\($0.symbol):\($0.count)" },
                       ["text.alignleft:2", "textformat:1", "doc:1"])
        XCTAssertEqual(groups[1].badges.map { "\($0.symbol):\($0.count)" }, ["text.alignleft:1"])
    }

    func testImageFilesClassifyAsImages() {
        let photo = ClipSnapshot(parts: [:], files: [ClipFile(name: "IMG_0042.HEIC", data: Data([1]))])
        XCTAssertEqual(photo.category, .image)
        XCTAssertEqual(photo.contentLabel, "image file")

        let photos = ClipSnapshot(parts: [:], files: [ClipFile(name: "a.png", data: Data([1])),
                                                      ClipFile(name: "b.jpg", data: Data([2]))])
        XCTAssertEqual(photos.category, .image)
        XCTAssertEqual(photos.contentLabel, "2 image files")

        let mixed = ClipSnapshot(parts: [:], files: [ClipFile(name: "a.png", data: Data([1])),
                                                     ClipFile(name: "notes.pdf", data: Data([2]))])
        XCTAssertEqual(mixed.category, .file)
        XCTAssertEqual(mixed.contentLabel, "2 files")

        // Picture files preview their content; other files have no thumbnail.
        let photoItem = HistoryItem(snapshot: photo, hash: "h1", timestamp: 0, label: "", source: "Home")
        XCTAssertEqual(photoItem.imageData, Data([1]))
        let mixedItem = HistoryItem(snapshot: mixed, hash: "h2", timestamp: 0, label: "", source: "Home")
        XCTAssertNil(mixedItem.imageData)
    }

    func testGroupsSubSectionByTypePreservingIndexOrder() {
        let model = makeModel()
        // Interleaved on purpose: file, text, image-file, text.
        load(model, [item("f.pdf", source: "Home", file: true),
                     item("hello", source: "Home"),
                     item("cat.jpg", source: "Home", file: true),
                     item("world", source: "Home")])

        let g = model.grouped[0]
        XCTAssertEqual(g.sections.map(\.title), ["Text", "Images", "Files"])
        XCTAssertEqual(g.sections.map { $0.entries.map(\.item.label) },
                       [["hello", "world"], ["cat.jpg"], ["f.pdf"]])
        // Flat indices follow the sub-sectioned display order and match filtered.
        XCTAssertEqual(g.entries.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(model.filtered.map(\.label), ["hello", "world", "cat.jpg", "f.pdf"])
    }

    func testImageFilterIncludesPictureFiles() {
        let model = makeModel()
        load(model, [item("hello", source: "Home"),
                     item("cat.jpg", source: "Home", file: true),
                     item("f.pdf", source: "Home", file: true)])
        model.kindFilter = .image
        XCTAssertEqual(model.filtered.map(\.label), ["cat.jpg"])
        model.kindFilter = .file
        XCTAssertEqual(model.filtered.map(\.label), ["f.pdf"])
    }

    /// RTF outranks image parts: a formatted-text copy that also carries a TIFF
    /// rendering of the selection (Excel, Word, …) is still a text copy; a real
    /// image copy has no RTF and stays "image".
    func testContentLabelClassifiesRenderedRichTextAsRichNotImage() {
        let officeStyle = ClipSnapshot(parts: [.text: Data("cells".utf8),
                                               .rtf: Data("{\\rtf1}".utf8),
                                               .tiff: Data([0x4D, 0x4D])])
        XCTAssertEqual(officeStyle.contentLabel, "rich text")

        let realImage = ClipSnapshot(parts: [.png: Data([0x89, 0x50]), .tiff: Data([0x4D, 0x4D])])
        XCTAssertEqual(realImage.contentLabel, "image")

        let browserImage = ClipSnapshot(parts: [.tiff: Data([0x4D, 0x4D]),
                                                .text: Data("https://example.com/cat.png".utf8)])
        XCTAssertEqual(browserImage.contentLabel, "image")
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
        load(model, [item("a", source: "Home"), item("f.pdf", source: "Home", file: true)])
        var savedGroups: Set<String>?
        var savedSubs: Set<String>?
        model.onCollapsedChange = { savedGroups = $0; savedSubs = $1 }
        model.toggleGroup("Home")
        XCTAssertEqual(savedGroups, ["Home"])
        model.toggleGroup("Home")
        XCTAssertEqual(savedGroups, [])
        model.toggleSub("Home", "Files")
        XCTAssertEqual(savedSubs, [PickerModel.subKey("Home", "Files")])
    }

    func testSubSectionCollapseHidesRowsKeepsHeaderCount() {
        let model = makeModel()
        load(model, [item("hello", source: "Home"), item("world", source: "Home"),
                     item("f.pdf", source: "Home", file: true), item("c", source: "HCL")])

        model.toggleSub("Home", "Text")
        // Text rows hidden; Files row and HCL re-index from 0.
        XCTAssertEqual(model.filtered.map(\.label), ["f.pdf", "c"])
        let home = model.grouped[0]
        XCTAssertEqual(home.total, 3)   // total badge unaffected by folding
        let textSection = home.sections[0]
        XCTAssertTrue(textSection.isCollapsed)
        XCTAssertEqual(textSection.count, 2)
        XCTAssertTrue(textSection.entries.isEmpty)
        XCTAssertEqual(home.sections[1].entries.map(\.index), [0])
        XCTAssertEqual(model.grouped[1].entries.map(\.index), [1])

        model.toggleSub("Home", "Text")
        XCTAssertEqual(model.filtered.count, 4)
    }

    func testGroupTotalCountsAllItemsUnderFilter() {
        let model = makeModel()
        load(model, [item("a", source: "Home"), item("styled", source: "Home", rich: true),
                     item("f.pdf", source: "Home", file: true)])
        XCTAssertEqual(model.grouped[0].total, 3)
        model.kindFilter = .file
        XCTAssertEqual(model.grouped[0].total, 1)
    }

    func testBadgesRespectActiveKindFilter() {
        let model = makeModel()
        load(model, [item("a", source: "Home"), item("f.txt", source: "Home", file: true)])
        model.kindFilter = .file
        XCTAssertEqual(model.grouped[0].badges.map { "\($0.symbol):\($0.count)" }, ["doc:1"])
    }
}
