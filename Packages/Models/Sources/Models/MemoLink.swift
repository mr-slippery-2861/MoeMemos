import Foundation

public struct MemoLink: Hashable, Sendable {
    public let server: URL
    public let memoID: String

    public init?(server: String, memoID: String) {
        guard let server = Self.serverURL(from: server) else { return nil }
        let id = memoID.hasPrefix("memos/") ? String(memoID.dropFirst("memos/".count)) : memoID
        guard id.wholeMatch(of: /[A-Za-z0-9_-]{1,256}/) != nil else { return nil }
        self.server = server
        self.memoID = id
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "moememos", components.host == "memo",
              components.path.isEmpty || components.path == "/",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil else { return nil }
        let server = components.queryItems?.filter { $0.name == "server" }
        let id = components.queryItems?.filter { $0.name == "id" }
        guard server?.count == 1, id?.count == 1,
              let server = server?.first?.value, let id = id?.first?.value else { return nil }
        self.init(server: server, memoID: id)
    }

    public init?(account: Account, memoID: String) {
        switch account {
        case .local: return nil
        case .memosV0(let host, _, _), .memosV1(let host, _, _):
            self.init(server: host, memoID: memoID)
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "moememos"
        components.host = "memo"
        components.queryItems = [
            URLQueryItem(name: "server", value: server.absoluteString),
            URLQueryItem(name: "id", value: memoID)
        ]
        return components.url!
    }

    public func matches(_ account: Account) -> Bool {
        MemoLink(account: account, memoID: memoID)?.server == server
    }

    public func remoteID(for account: Account) -> String? {
        guard matches(account) else { return nil }
        switch account {
        case .local: return nil
        case .memosV0:
            guard let number = Int(memoID), number > 0 else { return nil }
            return String(number)
        case .memosV1:
            return "memos/\(memoID)"
        }
    }

    private static func serverURL(from address: String) -> URL? {
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        return components.url
    }
}
