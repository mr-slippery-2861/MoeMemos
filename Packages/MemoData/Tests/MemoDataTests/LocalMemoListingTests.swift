import Foundation
import Models
import SwiftData
import XCTest
@testable import MemoData

@MainActor
final class LocalMemoListingTests: XCTestCase {
    func testTagListingUsesSavedMemosFromTheCurrentAccount() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let service = LocalService(context: context, accountKey: "local")
        let memo = insert("#Swift #work/project and `#hidden`", into: context)
        insert("#Alpha #Swift", into: context)
        insert("#Archived", status: .archived, into: context)
        insert("#Deleted", deleted: true, into: context)
        insert("#OtherAccount", account: "other", into: context)
        try context.save()

        let original = try await service.listTags()
        XCTAssertEqual(original.map(\.name), ["Alpha", "Swift", "work/project"])

        _ = try await service.updateMemo(id: memo.id, content: "#Edited", resources: nil,
                                         visibility: nil, tags: nil, pinned: nil, location: nil)
        let updated = try await service.listTags()
        XCTAssertEqual(updated.map(\.name), ["Alpha", "Edited", "Swift"])
    }

    func testListKeepsPinsFirstAndOrdersBothGroupsByCreationDate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        insert("Latest unpinned", age: 1, into: context)
        insert("Earlier pin", age: 4, pinned: true, into: context)
        insert("Earlier unpinned", age: 3, into: context)
        insert("Latest pin", age: 2, pinned: true, into: context)
        insert("Archived pin", pinned: true, status: .archived, into: context)
        try context.save()
        let store = LocalStore(context: context, accountKey: "local")

        XCTAssertEqual(store.listMemos(rowStatus: .normal).map(\.content),
                       ["Latest pin", "Earlier pin", "Latest unpinned", "Earlier unpinned"])
        XCTAssertEqual(store.listMemos(rowStatus: .normal, limit: 2, offset: 1).map(\.content),
                       ["Earlier pin", "Latest unpinned"])
        XCTAssertEqual(store.listMemos(rowStatus: .archived).map(\.content), ["Archived pin"])
    }

    func testAttachmentOrderSurvivesReloadAndServerReconciliation() throws {
        let container = try makeContainer()
        let store = LocalStore(context: container.mainContext, accountKey: "local")
        let memo = insert("Memo", into: container.mainContext)
        let first = Resource(filename: "first.txt", size: 10, mimeType: "text/plain",
                             createdAt: Date(), updatedAt: Date(), remoteId: "attachments/first",
                             url: URL(string: "https://memos.example/file/first")!)
        let second = Resource(filename: "second.txt", size: 10, mimeType: "text/plain",
                              createdAt: Date().addingTimeInterval(10), updatedAt: Date(), remoteId: "attachments/second",
                              url: URL(string: "https://memos.example/file/second")!)
        store.reconcileResources([first, second], to: memo)
        try store.save()
        let id = memo.persistentModelID
        let reloaded = try XCTUnwrap(ModelContext(container).model(for: id) as? StoredMemo)
        XCTAssertEqual(reloaded.orderedResources.map(\.filename), ["first.txt", "second.txt"])

        store.setResources(Array(memo.orderedResources.reversed()).map(\.persistentModelID), for: memo)
        try store.save()
        let reordered = try XCTUnwrap(ModelContext(container).model(for: id) as? StoredMemo)
        XCTAssertEqual(reordered.orderedResources.map(\.filename), ["second.txt", "first.txt"])
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: User.self, StoredMemo.self, StoredResource.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @discardableResult
    private func insert(_ content: String, age: TimeInterval = 0, pinned: Bool = false, status: RowStatus = .normal,
                        deleted: Bool = false, account: String = "local", into context: ModelContext) -> StoredMemo {
        let date = Date(timeIntervalSinceReferenceDate: -age)
        let memo = StoredMemo(accountKey: account, content: content, pinned: pinned, rowStatus: status,
                              visibility: .private, createdAt: date, updatedAt: date, softDeleted: deleted)
        context.insert(memo)
        return memo
    }
}
