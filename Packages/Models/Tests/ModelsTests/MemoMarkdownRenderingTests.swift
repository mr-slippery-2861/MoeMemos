import Markdown
import XCTest
@testable import Models

final class MemoMarkdownRenderingTests: XCTestCase {
    func testSmallDocumentsKeepOneSelectableTextView() {
        let document = Document(parsing: "Hello **world**.\n\n- [ ] Task\n\n> Quote")
        let rendered = MemoMarkdownRendering.documents(in: document)
        XCTAssertEqual(rendered.count, 1)
        XCTAssertTrue(rendered[0].isIdentical(to: document))
    }

    func testManyTablesAreRenderedInBoundedSegmentsWithoutLosingContent() {
        let table = "| Heading | Value |\n| --- | --- |\n| Hello | world |\n\n"
        let document = Document(parsing: String(repeating: table, count: 100))
        let rendered = MemoMarkdownRendering.documents(in: document)
        XCTAssertGreaterThan(rendered.count, 1)
        XCTAssertTrue(rendered.allSatisfy { $0.childCount <= 8 })
        let reconstructed = document.withUncheckedChildren(rendered.flatMap { Array($0.children) })
        XCTAssertEqual(reconstructed.format(), document.format())
    }

    func testLongOrderedTaskListsKeepTheirNumberingAndNestedContent() throws {
        let source = (20..<60).map { "\($0). [ ] Task \($0)\n    - Nested content" }.joined(separator: "\n")
        let document = Document(parsing: source)
        let rendered = MemoMarkdownRendering.documents(in: document)
        XCTAssertGreaterThan(rendered.count, 1)
        let lists = try rendered.map { try XCTUnwrap($0.child(at: 0) as? OrderedList) }
        XCTAssertEqual(lists.map(\.startIndex), [20, 28, 36, 44, 52])
        XCTAssertEqual(lists.reduce(0) { $0 + $1.childCount }, 40)
        XCTAssertTrue(rendered.allSatisfy { $0.format().contains("Nested content") })
        let laterTask = try XCTUnwrap(lists[2].child(at: 1) as? ListItem)
        let updated = try XCTUnwrap(MemoMarkdownRendering.togglingTask(laterTask, in: document))
        XCTAssertTrue(updated.format().contains("[x] Task 37"))
        XCTAssertTrue(updated.format().contains("[ ] Task 59"))
    }

    func testTogglingATaskInALaterSegmentPreservesTheEntireDocument() throws {
        let source = (0..<40).map { "- [ ] Duplicate task \($0)" }.joined(separator: "\n")
        let document = Document(parsing: source + "\n\n[reference]: https://example.com\n")
        let rendered = MemoMarkdownRendering.documents(in: document)
        let laterList = try XCTUnwrap(rendered[3].child(at: 0) as? UnorderedList)
        let item = try XCTUnwrap(laterList.child(at: 2) as? ListItem)
        let updated = try XCTUnwrap(MemoMarkdownRendering.togglingTask(item, in: document))
        let list = try XCTUnwrap(updated.child(at: 0) as? UnorderedList)
        let items = Array(list.listItems)
        XCTAssertEqual(items.count, 40)
        XCTAssertEqual(items.filter { $0.checkbox == .checked }.count, 1)
        XCTAssertEqual(items[26].checkbox, .checked)
        XCTAssertEqual(items[25].checkbox, .unchecked)
        XCTAssertTrue(updated.format().contains("Duplicate task 39"))
    }

    func testSegmentsKeepResolvedReferenceLinks() {
        let source = String(repeating: "> [A reference][target]\n\n", count: 30)
            + "[target]: https://example.com/path\n"
        let document = Document(parsing: source)
        let rendered = MemoMarkdownRendering.documents(in: document)
        XCTAssertGreaterThan(rendered.count, 1)
        for segment in rendered {
            XCTAssertTrue(segment.format().contains("https://example.com/path"))
        }
    }

    func testTaskWithoutASourceRangeCannotReplaceTheDocument() {
        let generated = ListItem(checkbox: .unchecked, Paragraph(Text("Generated task")))
        let document = Document(parsing: "- [ ] Saved task")
        XCTAssertNil(MemoMarkdownRendering.togglingTask(generated, in: document))
        XCTAssertTrue(document.format().contains("[ ] Saved task"))
    }
}
