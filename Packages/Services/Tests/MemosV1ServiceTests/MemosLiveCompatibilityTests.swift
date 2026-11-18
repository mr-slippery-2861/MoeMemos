import Foundation
import Models
import XCTest
@testable import MemosV1Service

@MainActor
final class MemosLiveCompatibilityTests: XCTestCase {
    // Supply a private JSON file with url, token and readOnly to run against a real instance.
    func testLiveCompatibility() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOE_MEMOS_COMPAT_CONFIG"] else {
            throw XCTSkip("No live Memos test instance configured.")
        }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let anonymous = MemosV1Service(hostURL: configuration.url, accessToken: nil, userId: nil)
        let profile = try await anonymous.getWorkspaceProfile()
        XCTAssertEqual(profile.version, "26.11.1")
        let login = MemosV1Service(hostURL: configuration.url, accessToken: configuration.token, userId: nil)
        let user = try await login.getCurrentUser()
        let userID = try XCTUnwrap(user.remoteId)
        let service = MemosV1Service(hostURL: configuration.url, accessToken: configuration.token, userId: userID)
        _ = try await service.listMemos()
        _ = try await service.listArchivedMemos()
        _ = try await service.listWorkspaceMemos(pageSize: 1, pageToken: nil)
        guard !configuration.readOnly else { return }

        let limits = try await service.memoWriteLimits()
        XCTAssertEqual(limits.contentBytes, 8192)
        XCTAssertThrowsError(try limits.validate(content: String(repeating: "汉", count: 2731)))
        _ = try await service.listSpaces()

        let viewTitle = "iOS check " + UUID().uuidString
        try await service.saveView(id: nil, title: viewTitle, filter: "has_location")
        let views = try await service.listSavedViews()
        let view = try XCTUnwrap(views.first { $0.title == viewTitle })
        try await service.saveView(id: view.id, title: viewTitle + " edited", filter: "has_location")
        try await service.deleteView(id: view.id)

        let file = Data(repeating: 97, count: 1_200_000)
        let resource = try await service.createResource(filename: "memos-compat.txt", data: file, type: "text/plain", memoRemoteId: nil)
        let content = "iOS compatibility " + UUID().uuidString
        let created = try await service.createMemo(
            content: content, visibility: .private, resources: [resource], tags: nil,
            createdAt: nil, updatedAt: nil, location: MemoLocation(placeholder: "Test", latitude: 30, longitude: 120)
        )
        let id = try XCTUnwrap(created.remoteId)
        do {
            let downloaded = try await service.downloadData(url: resource.url)
            XCTAssertEqual(downloaded, file)
            let results = try await service.listMemos(filter: "has_location", pageToken: nil)
            XCTAssertTrue(results.list.contains { $0.remoteId == id })
            let comment = try await service.createMemoComment(memoRemoteId: id, content: "Test reply")
            let comments = try await service.listMemoComments(memoRemoteId: id)
            XCTAssertEqual(comments.map(\.remoteId), [comment.remoteId])

            try await service.toggleReaction(memo: id, emoji: "🏳️‍🌈", existing: nil)
            let reactions = try await service.listReactions(memo: id)
            let reaction = try XCTUnwrap(reactions.first)
            XCTAssertEqual(reaction.emoji, "🏳️‍🌈")
            XCTAssertTrue(reaction.isMine)
            try await service.toggleReaction(memo: id, emoji: reaction.emoji, existing: reaction)

            try await service.createShareLink(memo: id, expires: .now.addingTimeInterval(3600))
            let links = try await service.listShareLinks(memo: id)
            let link = try XCTUnwrap(links.first)
            XCTAssertNotNil(link.expiry)
            XCTAssertTrue(link.url.path.contains("memos/shares/"))
            try await service.revokeShareLink(memo: id, share: link.id)

            let updated = try await service.updateMemo(remoteId: id, content: content + " edited", resources: nil,
                                                       visibility: nil, tags: nil, pinned: true, updatedAt: .now)
            XCTAssertTrue(updated.pinned)
            try await service.archiveMemo(remoteId: id)
            let archived = try await service.listArchivedMemos()
            XCTAssertTrue(archived.contains { $0.remoteId == id })
            try await service.restoreMemo(remoteId: id)
        } catch {
            try? await service.deleteMemo(remoteId: id)
            throw error
        }
        try await service.deleteMemo(remoteId: id)
    }

    private struct Configuration: Decodable {
        let url: URL
        let token: String
        let readOnly: Bool
    }
}
