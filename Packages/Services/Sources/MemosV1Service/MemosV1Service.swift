//
//  MemosV1Service.swift
//
//
//  Created by Mudkip on 2024/6/9.
//

import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import HTTPTypes
import Models
import ServiceUtils

@MainActor
public final class MemosV1Service: RemoteService, MemoCommentService, MemoWritePolicyService, MemosWorkspaceService {
    private let hostURL: URL
    private let urlSession: URLSession
    private let client: Client
    private let accessToken: String?
    private let userId: String?
    private var detectedVersion: SemanticVersion?
    private let grpcSetCookieMiddleware = GRPCSetCookieMiddleware()
    
    public nonisolated init(hostURL: URL, accessToken: String?, userId: String?, transport: (any ClientTransport)? = nil) {
        self.hostURL = hostURL
        self.accessToken = accessToken
        self.userId = userId
        urlSession = URLSession(configuration: URLSessionConfiguration.default)
        client = Client(
            serverURL: hostURL,
            transport: transport ?? URLSessionTransport(configuration: .init(session: urlSession)),
            middlewares: [
                AccessTokenAuthenticationMiddleware(accessToken: accessToken),
                MemosAPIRoutingMiddleware(),
                grpcSetCookieMiddleware
            ]
        )
    }
    
    public var supportsMemoLocations: Bool { true }

    public func memoVisibilities() -> [MemoVisibility] {
        return [.private, .local, .public]
    }
    
    public func listMemos() async throws -> [Memo] {
        guard let userId = userId else { throw MoeMemosError.notLogin }
        var memos = [Memo]()
        var nextPageToken: String? = nil
        
        repeat {
            let resp = try await client.MemoService_ListMemos(query: .init(pageSize: 200, pageToken: nextPageToken, state: .NORMAL, filter: "creator == \"users/\(userId)\""))
            let data = try resp.ok.body.json
            memos += data.memos?.map { $0.toMemo(host: hostURL) } ?? []
            nextPageToken = data.nextPageToken
        } while (nextPageToken?.isEmpty == false)
        
        return memos
    }
    
    public func listArchivedMemos() async throws -> [Memo] {
        guard let userId = userId else { throw MoeMemosError.notLogin }
        var memos = [Memo]()
        var nextPageToken: String? = nil
        
        repeat {
            let resp = try await client.MemoService_ListMemos(query: .init(pageSize: 200, pageToken: nextPageToken, state: .ARCHIVED, filter: "creator == \"users/\(userId)\""))
            let data = try resp.ok.body.json
            memos += data.memos?.map { $0.toMemo(host: hostURL) } ?? []
            nextPageToken = data.nextPageToken
        } while (nextPageToken?.isEmpty == false)
        
        return memos
    }
    
    public func listWorkspaceMemos(pageSize: Int, pageToken: String?) async throws -> (list: [Memo], nextPageToken: String?) {
        let resp = try await client.MemoService_ListMemos(query: .init(pageSize: Int32(pageSize), pageToken: pageToken, filter: "visibility in [\"PUBLIC\", \"PROTECTED\"]"))
        let data = try resp.ok.body.json
        let memos = data.memos ?? []
        let result = await memosWithUsers(memos)

        let nextPageToken = data.nextPageToken?.isEmpty == true ? nil : data.nextPageToken
        return (result, nextPageToken)
    }
    
    public func createMemo(
        content: String,
        visibility: MemoVisibility?,
        resources: [Resource],
        tags: [String]?,
        createdAt: Date?,
        updatedAt: Date?,
        location: MemoLocation? = nil
    ) async throws -> Memo {
        if let location, !location.isValid { throw MoeMemosError.invalidParams }
        _ = tags
        let memosResources: [MemosV1Resource] = resources.compactMap {
            var resource: MemosV1Resource? = nil
            if let remoteId = $0.remoteId {
                resource = MemosV1Resource(name: getName(remoteId: remoteId))
            }
            return resource
        }
        
        let resp = try await client.MemoService_CreateMemo(body: .json(.init(
            createTime: createdAt,
            updateTime: updatedAt,
            content: content,
            visibility: visibility.map(MemosV1Visibility.init(memoVisibility:)),
            attachments: memosResources,
            location: location.map { .init(value1: .init(placeholder: $0.placeholder, latitude: $0.latitude, longitude: $0.longitude)) }
        )))
        let memo = try resp.ok.body.json
        
        let result = memo.toMemo(host: hostURL)
        return result
    }
    
    public func updateMemo(
        remoteId: String,
        content: String?,
        resources: [Resource]?,
        visibility: MemoVisibility?,
        tags: [String]?,
        pinned: Bool?,
        updatedAt: Date?,
        location: MemoLocationUpdate? = nil
    ) async throws -> Memo {
        if let value = location?.location, !value.isValid { throw MoeMemosError.invalidParams }
        _ = tags
        let memosResources: [MemosV1Resource]? = resources?.compactMap {
            var resource: MemosV1Resource? = nil
            if let remoteId = $0.remoteId {
                resource = MemosV1Resource(name: getName(remoteId: remoteId))
            }
            return resource
        }

        var mask = ["update_time"]
        if content != nil { mask.append("content") }
        if visibility != nil { mask.append("visibility") }
        if pinned != nil { mask.append("pinned") }
        if resources != nil { mask.append("attachments") }
        if location != nil { mask.append("location") }
        let resp = try await client.MemoService_UpdateMemo(path: .init(memo: getId(remoteId: remoteId)), query: .init(updateMask: mask.joined(separator: ",")), body: .json(.init(
            updateTime: updatedAt ?? .now,
            content: content,
            visibility: visibility.map(MemosV1Visibility.init(memoVisibility:)),
            pinned: pinned,
            attachments: memosResources,
            location: location?.location.map { .init(value1: .init(placeholder: $0.placeholder, latitude: $0.latitude, longitude: $0.longitude)) }
        )))
        let memo = try resp.ok.body.json
        let result = memo.toMemo(host: hostURL)
        return result
    }
    
    public func deleteMemo(remoteId: String) async throws {
        let resp = try await client.MemoService_DeleteMemo(path: .init(memo: getId(remoteId: remoteId)))
        _ = try resp.ok
    }

    public func listMemoComments(memoRemoteId: String) async throws -> [Memo] {
        var comments = [MemosV1Memo]()
        var nextPageToken: String? = nil

        repeat {
            let resp = try await client.MemoService_ListMemoComments(path: .init(memo: getId(remoteId: memoRemoteId)), query: .init(pageSize: 200, pageToken: nextPageToken, orderBy: nil))
            let data = try resp.ok.body.json
            comments += data.comments ?? data.memos ?? []
            nextPageToken = data.nextPageToken
        } while (nextPageToken?.isEmpty == false)

        return await memosWithUsers(comments)
    }

    public func createMemoComment(memoRemoteId: String, content: String) async throws -> Memo {
        let resp = try await client.MemoService_CreateMemoComment(path: .init(memo: getId(remoteId: memoRemoteId)), query: .init(commentId: nil), body: .json(.init(content: content)))
        let comment = try resp.ok.body.json
        return await memosWithUsers([comment]).first ?? comment.toMemo(host: hostURL)
    }
    
    public func archiveMemo(remoteId: String) async throws {
        let resp = try await client.MemoService_UpdateMemo(path: .init(memo: getId(remoteId: remoteId)), query: .init(updateMask: "state"), body: .json(.init(state: .ARCHIVED)))
        _ = try resp.ok
    }

    public func restoreMemo(remoteId: String) async throws {
        let resp = try await client.MemoService_UpdateMemo(path: .init(memo: getId(remoteId: remoteId)), query: .init(updateMask: "state"), body: .json(.init(state: .NORMAL)))
        _ = try resp.ok
    }

    public func listTags() async throws -> [Tag] {
        guard let userId = userId else { throw MoeMemosError.notLogin }
        let resp = try await client.UserService_GetUserStats(path: .init(user: "\(userId)"))
        let data = try resp.ok.body.json
        
        var tags = [Tag]()
        if let tagCount = data.tagCounts?.additionalProperties ?? data.tagCount?.additionalProperties {
            for (tag, _) in tagCount {
                tags.append(.init(name: tag))
            }
        }
        return tags
    }
    
    public func listResources() async throws -> [Resource] {
        var resources: [Resource] = []
        var pageToken: String?
        repeat {
            let resp = try await client.AttachmentService_ListAttachments(query: .init(pageSize: 100, pageToken: pageToken))
            let data = try resp.ok.body.json
            resources += data.attachments?.map { $0.toResource(host: hostURL) } ?? []
            pageToken = data.nextPageToken
        } while pageToken?.isEmpty == false
        return resources
    }

    public func createResource(filename: String, data: Data, type: String, memoRemoteId: String?) async throws -> Resource {
        if data.count > 1_048_576, (try? await usesCalendarAPI()) == true {
            return try await uploadInChunks(filename: filename, data: data, type: type, memoRemoteId: memoRemoteId)
        }
        let resp = try await client.AttachmentService_CreateAttachment(body: .json(.init(
            filename: filename,
            content: .init(data),
            _type: type,
            memo: memoRemoteId.map(getName(remoteId:))
        )))
        let data = try resp.ok.body.json
        return data.toResource(host: hostURL)
    }
    
    public func deleteResource(remoteId: String) async throws {
        let resp = try await client.AttachmentService_DeleteAttachment(path: .init(attachment: getId(remoteId: remoteId)))
        _ = try resp.ok
    }
    
    public func getCurrentUser() async throws -> UserSnapshot {
        let resp = try await client.AuthService_GetCurrentUser()

        let user: MemosV1User
        switch resp {
        case .ok(let ok):
            let json = try ok.body.json
            guard let fetchedUser = json.user?.value1 else {
                throw MoeMemosError.notLogin
            }
            user = fetchedUser
        case .default(statusCode: let statusCode, let defaultResponse):
            if statusCode == 401 || statusCode == 403 {
                throw MoeMemosError.accessTokenExpired
            }
            let message = (try? defaultResponse.body.json.message)
            throw MoeMemosError.invalidStatusCode(statusCode, message)
        }
        
        guard let name = user.name else { throw MoeMemosError.unsupportedVersion }
        let userSettingResp = try await client.UserService_GetUserSetting(path: .init(user: getId(remoteId: name), setting: "GENERAL"))
        
        let setting = try userSettingResp.ok.body.json
        return await toUserSnapshot(user, setting: setting)
    }
    
    public func getWorkspaceProfile() async throws -> MemosV1Profile {
        let resp = try await client.InstanceService_GetInstanceProfile()
        let profile = try resp.ok.body.json
        detectedVersion = profile.version.flatMap(SemanticVersion.init)
        return profile
    }

    public func download(url: URL, mimeType: String? = nil) async throws -> URL {
        return try await ServiceUtils.download(urlSession: urlSession, url: url, mimeType: mimeType, middleware: rawAccessTokenMiddlware(hostURL: hostURL, accessToken: accessToken))
    }
    
    func downloadData(url: URL) async throws -> Data {
        return try await ServiceUtils.downloadData(urlSession: urlSession, url: url, middleware: rawAccessTokenMiddlware(hostURL: hostURL, accessToken: accessToken))
    }
    
    private func getName(remoteId: String) -> String {
        return remoteId.split(separator: "|").first.map(String.init) ?? ""
    }
    
    private func getId(remoteId: String) -> String {
        return remoteId.split(separator: "|").first?.split(separator: "/").last.map(String.init) ?? ""
    }

    /// Converts raw memos to `Memo` models and fills in `user` from the creators' profiles.
    func memosWithUsers(_ memos: [MemosV1Memo]) async -> [Memo] {
        let creators = Set(memos.compactMap(\.creator))
        var userMap = [String: MemosV1User]()
        for creator in creators {
            let userId = getId(remoteId: creator)
            guard !userId.isEmpty else { continue }
            guard let userResp = try? await client.UserService_GetUser(path: .init(user: userId), query: .init(readMask: nil)) else { continue }
            guard let user = try? userResp.ok.body.json else { continue }
            guard let name = user.name else { continue }
            userMap[name] = user
        }

        return memos.map { rawMemo in
            var memo = rawMemo.toMemo(host: hostURL)
            if let creator = rawMemo.creator, let user = userMap[creator] {
                memo.user = RemoteUser(
                    nickname: user.displayName ?? user.username,
                    creationDate: user.createTime ?? .now,
                    remoteId: user.name.map { getId(remoteId: $0) }
                )
            }
            return memo
        }
    }
    
    func toUserSnapshot(_ memosUser: MemosV1User, setting: Components.Schemas.UserSetting? = nil) async -> UserSnapshot {
        let remoteId = getId(remoteId: memosUser.name ?? "0")
        let key = "memos:\(hostURL.absoluteString):\(remoteId)"
        var snapshot = UserSnapshot(
            accountKey: key,
            nickname: memosUser.displayName ?? memosUser.username,
            avatarData: nil,
            defaultVisibility: .private,
            creationDate: memosUser.createTime ?? .now,
            email: memosUser.email,
            remoteId: remoteId
        )
        if let avatarUrl = memosUser.avatarUrl, let url = URL(string: avatarUrl) {
            var url = url
            if url.host() == nil {
                url = hostURL.appending(path: avatarUrl)
            }
            snapshot.avatarData = try? await downloadData(url: url)
        }
        if let visibilityString = setting?.generalSetting?.memoVisibility, let visibility = MemosV1Visibility(rawValue: visibilityString) {
            snapshot.defaultVisibility = visibility.toMemoVisibility()
        }
        snapshot.isAdmin = memosUser.role == .ADMIN
        return snapshot
    }
}

extension MemosV1Service {
    public var webURL: URL { hostURL }

    public func supportsCollections() async throws -> Bool {
        try await version() >= SemanticVersion("0.31.0")!
    }

    public func memoWriteLimits() async throws -> MemoWriteLimits {
        guard let userId else { throw MoeMemosError.notLogin }
        if try await usesCalendarAPI() {
            let result = try await client.UserService_GetUserUsage(path: .init(user: userId))
            let limits = try result.ok.body.json.limits
            return MemoWriteLimits(
                contentBytes: limits?.memoContentBytes.flatMap(Int.init),
                uploadBytes: limits?.uploadBytes.flatMap(Int64.init)
            )
        }

        let result = try await client.InstanceService_GetInstanceSetting(path: .init(setting: "MEMO_RELATED"))
        let contentBytes = try result.ok.body.json.memoRelatedSetting?.contentLengthLimit.map(Int.init)
        // Legacy storage settings may require instance administrator privileges.
        let storage = try? await client.InstanceService_GetInstanceSetting(path: .init(setting: "STORAGE"))
        let megabytes = try? storage?.ok.body.json.storageSetting?.uploadSizeLimitMb.flatMap(Int64.init)
        let uploadBytes = megabytes.flatMap { size -> Int64? in
            let (bytes, overflow) = size.multipliedReportingOverflow(by: 1_048_576)
            return overflow ? nil : bytes
        }
        return MemoWriteLimits(contentBytes: contentBytes, uploadBytes: uploadBytes)
    }

    public func listSpaces() async throws -> [MemosSpace] {
        var spaces: [MemosSpace] = []
        var pageToken: String?
        repeat {
            let result = try await client.SpaceService_ListSpaces(query: .init(pageSize: 100, pageToken: pageToken))
            let page = try result.ok.body.json
            spaces += (page.spaces ?? []).compactMap { space in
                guard let name = space.name, let title = space.title else { return nil }
                return MemosSpace(id: name, title: title, emoji: space.icon?.emoji)
            }
            pageToken = page.nextPageToken
        } while pageToken?.isEmpty == false
        return spaces
    }

    public func createSpace(title: String, description: String) async throws {
        let result = try await client.SpaceService_CreateSpace(body: .json(.init(title: title, description: description)))
        _ = try result.ok
    }

    public func memoPlacement(memo: String) async throws -> (space: String?, visibility: MemoVisibility) {
        let result = try await client.MemoService_GetMemo(path: .init(memo: getId(remoteId: memo)))
        let value = try result.ok.body.json
        return (value.space, value.visibility?.toMemoVisibility() ?? .private)
    }

    public func updateMemoPlacement(memo: String, space: String?, visibility: MemoVisibility) async throws {
        guard visibility != .space || space != nil else { throw MoeMemosError.invalidParams }
        let result = try await client.MemoService_UpdateMemo(
            path: .init(memo: getId(remoteId: memo)),
            query: .init(updateMask: "space,visibility"),
            body: .json(.init(space: space ?? "", visibility: .init(memoVisibility: visibility)))
        )
        _ = try result.ok
    }

    public func listSavedViews() async throws -> [SavedMemosView] {
        guard let userId else { throw MoeMemosError.notLogin }
        let result = try await client.UserService_ListMemoViews(path: .init(user: userId))
        return try (result.ok.body.json.memoViews ?? []).compactMap { view in
            guard let name = view.name, let title = view.title, let filter = view.filter else { return nil }
            return SavedMemosView(id: name, title: title, filter: filter, emoji: view.icon?.emoji)
        }
    }

    public func saveView(id: String?, title: String, filter: String) async throws {
        guard let userId else { throw MoeMemosError.notLogin }
        let body = Components.Schemas.SavedMemoView(title: title, filter: filter)
        if let id {
            let result = try await client.UserService_UpdateMemoView(
                path: .init(user: userId, view: getId(remoteId: id)),
                query: .init(updateMask: "title,filter"), body: .json(body)
            )
            _ = try result.ok
        } else {
            let result = try await client.UserService_CreateMemoView(path: .init(user: userId), body: .json(body))
            _ = try result.ok
        }
    }

    public func deleteView(id: String) async throws {
        guard let userId else { throw MoeMemosError.notLogin }
        let result = try await client.UserService_DeleteMemoView(path: .init(user: userId, view: getId(remoteId: id)))
        _ = try result.ok
    }

    public func listMemos(filter: String?, pageToken: String?) async throws -> (list: [Memo], nextPageToken: String?) {
        let result = try await client.MemoService_ListMemos(query: .init(pageSize: 30, pageToken: pageToken, state: .NORMAL, filter: filter))
        let page = try result.ok.body.json
        return ((page.memos ?? []).map { $0.toMemo(host: hostURL) }, page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 })
    }

    public func listReactions(memo: String) async throws -> [MemoReaction] {
        let result = try await client.MemoService_ListMemoReactions(path: .init(memo: getId(remoteId: memo)))
        return try (result.ok.body.json.reactions ?? []).compactMap { reaction in
            guard let name = reaction.name else { return nil }
            let isMine = userId.map { reaction.creator == "users/\($0)" } ?? false
            return MemoReaction(id: name, emoji: reaction.reactionType, isMine: isMine)
        }
    }

    public func toggleReaction(memo: String, emoji: String, existing: MemoReaction?) async throws {
        let memoID = getId(remoteId: memo)
        if let existing, existing.isMine {
            let result = try await client.MemoService_DeleteMemoReaction(path: .init(memo: memoID, reaction: getId(remoteId: existing.id)))
            _ = try result.ok
        } else {
            let result = try await client.MemoService_UpsertMemoReaction(
                path: .init(memo: memoID), body: .json(.init(reaction: .init(value1: .init(reactionType: emoji))))
            )
            _ = try result.ok
        }
    }

    public func listShareLinks(memo: String) async throws -> [MemoShareLink] {
        let result = try await client.MemoService_ListMemoShares(path: .init(memo: getId(remoteId: memo)))
        return try (result.ok.body.json.memoShares ?? []).compactMap { share in
            guard let name = share.name else { return nil }
            let url = hostURL.appending(path: "memos/shares").appending(component: getId(remoteId: name))
            return MemoShareLink(id: name, url: url, expiry: share.expireTime)
        }
    }

    public func createShareLink(memo: String, expires: Date?) async throws {
        let result = try await client.MemoService_CreateMemoShare(
            path: .init(memo: getId(remoteId: memo)), body: .json(.init(expireTime: expires))
        )
        _ = try result.ok
    }

    public func revokeShareLink(memo: String, share: String) async throws {
        let result = try await client.MemoService_DeleteMemoShare(
            path: .init(memo: getId(remoteId: memo), share: getId(remoteId: share))
        )
        _ = try result.ok
    }

    private func version() async throws -> SemanticVersion {
        if let detectedVersion { return detectedVersion }
        _ = try await getWorkspaceProfile()
        guard let detectedVersion else { throw MoeMemosError.unsupportedVersion }
        return detectedVersion
    }

    private func usesCalendarAPI() async throws -> Bool {
        try await version() >= SemanticVersion(SupportedMemosVersion.minimumCalendar)!
    }

    private func uploadInChunks(filename: String, data: Data, type: String, memoRemoteId: String?) async throws -> Resource {
        let attachment = MemosV1Resource(filename: filename, _type: type, memo: memoRemoteId.map(getName(remoteId:)))
        let start = try await client.AttachmentService_UploadAttachment(body: .json(.init(
            spec: .init(attachment: attachment, totalSize: String(data.count)), writeOffset: "0"
        )))
        let session = try start.ok.body.json
        guard let id = session.uploadId, let maximum = session.maxChunkSize, maximum > 0 else {
            throw MoeMemosError.unknown
        }
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = offset + min(data.count - offset, Int(maximum), 1_048_576)
            let chunk = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
            let result = try await client.AttachmentService_UploadAttachment(body: .json(.init(
                uploadId: id, writeOffset: String(offset), data: .init(chunk), finishWrite: end == data.count
            )))
            let progress = try result.ok.body.json
            if end == data.count, let finished = progress.attachment {
                return finished.toResource(host: hostURL)
            }
            guard progress.committedSize.flatMap(Int.init) == end else { throw MoeMemosError.unknown }
            offset = end
        }
        throw MoeMemosError.unknown
    }
}
