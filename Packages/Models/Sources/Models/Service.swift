//
//  File.swift
//  
//
//  Created by Mudkip on 2023/11/19.
//

import Foundation
import SwiftData

@MainActor
public protocol RemoteService: Sendable {
    var supportsMemoLocations: Bool { get }
    func memoVisibilities() -> [MemoVisibility]
    func listMemos() async throws -> [Memo]
    func listArchivedMemos() async throws -> [Memo]
    func listWorkspaceMemos(pageSize: Int, pageToken: String?) async throws -> (list: [Memo], nextPageToken: String?)
    func createMemo(
        content: String,
        visibility: MemoVisibility?,
        resources: [Resource],
        tags: [String]?,
        createdAt: Date?,
        updatedAt: Date?,
        location: MemoLocation?
    ) async throws -> Memo
    func updateMemo(
        remoteId: String,
        content: String?,
        resources: [Resource]?,
        visibility: MemoVisibility?,
        tags: [String]?,
        pinned: Bool?,
        updatedAt: Date?,
        location: MemoLocationUpdate?
    ) async throws -> Memo
    func deleteMemo(remoteId: String) async throws
    func archiveMemo(remoteId: String) async throws
    func restoreMemo(remoteId: String) async throws
    func listTags() async throws -> [Tag]
    func listResources() async throws -> [Resource]
    func createResource(filename: String, data: Data, type: String, memoRemoteId: String?) async throws -> Resource
    func deleteResource(remoteId: String) async throws
    func getCurrentUser() async throws -> UserSnapshot
    func download(url: URL, mimeType: String?) async throws -> URL
}

@MainActor
public protocol RemoteMemoReading: RemoteService {
    func readMemo(remoteId: String) async throws -> Memo
}

/// Remote services that support memo comments (Memos v1 API).
@MainActor
public protocol MemoCommentService: RemoteService {
    func listMemoComments(memoRemoteId: String) async throws -> [Memo]
    func createMemoComment(memoRemoteId: String, content: String) async throws -> Memo
}

/// Local-first service used by the app UI for both Local and Remote accounts.
/// Identifiers are SwiftData `PersistentIdentifier`s, not server ids.
@MainActor
public protocol Service: Sendable {
    var supportsMemoLocations: Bool { get }
    func memoVisibilities() -> [MemoVisibility]
    func listMemos() async throws -> [StoredMemo]
    func listArchivedMemos() async throws -> [StoredMemo]
    func memo(id: PersistentIdentifier) -> StoredMemo?

    func createMemo(content: String, visibility: MemoVisibility?, resources: [PersistentIdentifier], tags: [String]?, location: MemoLocation?) async throws -> StoredMemo
    func updateMemo(id: PersistentIdentifier, content: String?, resources: [PersistentIdentifier]?, visibility: MemoVisibility?, tags: [String]?, pinned: Bool?, location: MemoLocationUpdate?) async throws -> StoredMemo
    func deleteMemo(id: PersistentIdentifier) async throws
    func archiveMemo(id: PersistentIdentifier) async throws
    func restoreMemo(id: PersistentIdentifier) async throws

    func listTags() async throws -> [Tag]
    func listResources() async throws -> [StoredResource]
    func resource(id: PersistentIdentifier) -> StoredResource?
    func createResource(filename: String, data: Data, type: String, memoId: PersistentIdentifier?) async throws -> StoredResource
    func deleteResource(id: PersistentIdentifier) async throws

    func getCurrentUser() async throws -> User
    func ensureLocalResourceFile(id: PersistentIdentifier) async throws -> URL
}

@MainActor
public protocol SyncableService: Sendable {
    func sync() async throws
}

@MainActor
public protocol PendingOperationsService: Sendable {
    func waitForPendingOperations() async
}

public extension RemoteService {
    var supportsMemoLocations: Bool { false }

    func createMemo(content: String, visibility: MemoVisibility?, resources: [Resource], tags: [String]?, createdAt: Date?, updatedAt: Date?) async throws -> Memo {
        try await createMemo(content: content, visibility: visibility, resources: resources, tags: tags, createdAt: createdAt, updatedAt: updatedAt, location: nil)
    }

    func updateMemo(remoteId: String, content: String?, resources: [Resource]?, visibility: MemoVisibility?, tags: [String]?, pinned: Bool?, updatedAt: Date?) async throws -> Memo {
        try await updateMemo(remoteId: remoteId, content: content, resources: resources, visibility: visibility, tags: tags, pinned: pinned, updatedAt: updatedAt, location: nil)
    }
}

public extension Service {
    var supportsMemoLocations: Bool { true }

    func createMemo(content: String, visibility: MemoVisibility?, resources: [PersistentIdentifier], tags: [String]?) async throws -> StoredMemo {
        try await createMemo(content: content, visibility: visibility, resources: resources, tags: tags, location: nil)
    }

    func updateMemo(id: PersistentIdentifier, content: String?, resources: [PersistentIdentifier]?, visibility: MemoVisibility?, tags: [String]?, pinned: Bool?) async throws -> StoredMemo {
        try await updateMemo(id: id, content: content, resources: resources, visibility: visibility, tags: tags, pinned: pinned, location: nil)
    }
}

/// The effective per-note and per-file server limits, in bytes.
public struct MemoWriteLimits: Sendable, Equatable {
    public let contentBytes: Int?
    public let uploadBytes: Int64?

    public init(contentBytes: Int?, uploadBytes: Int64?) {
        self.contentBytes = contentBytes.flatMap { $0 > 0 ? $0 : nil }
        self.uploadBytes = uploadBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    public func validate(content: String) throws {
        if let contentBytes, content.utf8.count > contentBytes {
            throw MoeMemosError.memoTooLong(contentBytes)
        }
    }

    public func validate(uploadSize: Int64) throws {
        if let uploadBytes, uploadSize > uploadBytes {
            throw MoeMemosError.fileTooLarge(uploadBytes)
        }
    }
}

@MainActor
public protocol MemoWritePolicyService: RemoteService {
    func memoWriteLimits() async throws -> MemoWriteLimits
}

public struct MemosSpace: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let emoji: String?

    public init(id: String, title: String, emoji: String?) {
        self.id = id
        self.title = title
        self.emoji = emoji
    }
}

public struct SavedMemosView: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let filter: String
    public let emoji: String?

    public init(id: String, title: String, filter: String, emoji: String?) {
        self.id = id
        self.title = title
        self.filter = filter
        self.emoji = emoji
    }
}

public struct MemoReaction: Identifiable, Sendable {
    public let id: String
    public let emoji: String
    public let isMine: Bool

    public init(id: String, emoji: String, isMine: Bool) {
        self.id = id
        self.emoji = emoji
        self.isMine = isMine
    }
}

public struct MemoShareLink: Identifiable, Sendable {
    public let id: String
    public let url: URL
    public let expiry: Date?

    public init(id: String, url: URL, expiry: Date?) {
        self.id = id
        self.url = url
        self.expiry = expiry
    }
}

@MainActor
public protocol MemosWorkspaceService: RemoteService {
    var webURL: URL { get }
    func supportsCollections() async throws -> Bool
    func listSpaces() async throws -> [MemosSpace]
    func createSpace(title: String, description: String) async throws
    func memoPlacement(memo: String) async throws -> (space: String?, visibility: MemoVisibility)
    func updateMemoPlacement(memo: String, space: String?, visibility: MemoVisibility) async throws
    func listSavedViews() async throws -> [SavedMemosView]
    func saveView(id: String?, title: String, filter: String) async throws
    func deleteView(id: String) async throws
    func listMemos(filter: String?, pageToken: String?) async throws -> (list: [Memo], nextPageToken: String?)
    func listReactions(memo: String) async throws -> [MemoReaction]
    func toggleReaction(memo: String, emoji: String, existing: MemoReaction?) async throws
    func listShareLinks(memo: String) async throws -> [MemoShareLink]
    func createShareLink(memo: String, expires: Date?) async throws
    func revokeShareLink(memo: String, share: String) async throws
}
