import Account
import Env
import MemoData
import MemoKit
import Models
import SwiftUI

@MainActor
struct MemoLinkView: View {
    let link: MemoLink?

    @Environment(AccountManager.self) private var accounts
    @Environment(AccountViewModel.self) private var accountViewModel
    @Environment(AppPath.self) private var appPath
    @State private var selectedAccount: String?
    @State private var choosingAccount = false
    @State private var retry = 0
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case resolved(LinkedMemo, accountKey: String)
        case failed(LocalizedStringKey, signIn: Bool)
    }

    private struct Attempt: Equatable {
        let accountKey: String?
        let retry: Int
    }

    private var matchingUsers: [User] {
        guard let link else { return [] }
        return accountViewModel.users.filter { user in
            accounts.account(for: user.accountKey).map(link.matches) == true
        }
    }

    private func accountKey(in users: [User]) -> String? {
        guard !choosingAccount else { return nil }
        for candidate in [selectedAccount, accounts.currentAccount?.key].compactMap({ $0 }) {
            if users.contains(where: { $0.accountKey == candidate }) { return candidate }
        }
        return users.count == 1 ? users.first?.accountKey : nil
    }

    var body: some View {
        let users = matchingUsers
        let attempt = Attempt(accountKey: accountKey(in: users), retry: retry)
        Group {
            if case .resolved(.cached(let id), let accountKey) = phase,
               attempt.accountKey == accountKey, accounts.currentAccount?.key == accountKey {
                MemoView(memoId: id)
            } else {
                content(users: users, accountKey: attempt.accountKey)
                    .navigationTitle("Memo")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: attempt) { await load(accountKey: attempt.accountKey) }
    }

    @ViewBuilder
    private func content(users: [User], accountKey: String?) -> some View {
        if let link {
            if users.isEmpty {
                ContentUnavailableView {
                    Label("Sign In to Open This Memo", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Add your Memos account for \(link.server.absoluteString).")
                } actions: {
                    Button("account.add-account") { appPath.presentedSheet = .addAccount }
                        .buttonStyle(.borderedProminent)
                }
            } else if accountKey == nil {
                List(users, id: \.accountKey) { user in
                    Button {
                        phase = .loading
                        selectedAccount = user.accountKey
                        choosingAccount = false
                        retry += 1
                    } label: {
                        Label(user.nickname, systemImage: "person.crop.circle")
                    }
                }
                .navigationTitle("Choose Memos Account")
            } else {
                switch phase {
                case .resolved(.preview(let memo, let remote), let key) where key == accountKey:
                    preview(memo, remote: remote, link: link)
                case .resolved(.cached, let key) where key == accountKey:
                    ContentUnavailableView {
                        Label("Memo", systemImage: "note.text")
                    } description: {
                        if let user = users.first(where: { $0.accountKey == key }) { Text(user.nickname) }
                    } actions: {
                        Button("account.switch-account") {
                            phase = .loading
                            retry += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .loading, .resolved:
                    ProgressView("Loading memo…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message, let signIn):
                    ContentUnavailableView {
                        Label("Couldn’t Open Memo", systemImage: "note.text")
                    } description: {
                        Text(message)
                    } actions: {
                        if signIn {
                            Button("account.add-account") { appPath.presentedSheet = .addAccount }
                        }
                        Button("common.retry") {
                            phase = .loading
                            retry += 1
                        }
                        .buttonStyle(.borderedProminent)
                        if users.count > 1 {
                            Button("Choose Memos Account") { choosingAccount = true }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("Invalid Memo Link", systemImage: "link")
            } description: {
                Text("The link needs a Memos server address and a memo ID.")
            }
        }
    }

    private func load(accountKey: String?) async {
        phase = .loading
        guard let link, let accountKey else { return }
        do {
            let result = try await accounts.linkedMemo(link, for: accountKey)
            try Task.checkCancellation()
            if case .cached = result, accounts.currentAccount?.key != accountKey {
                try accounts.selectAccount(key: accountKey)
            }
            phase = .resolved(result, accountKey: accountKey)
        } catch {
            guard !Task.isCancelled else { return }
            switch error {
            case MoeMemosError.notLogin, MoeMemosError.accessTokenExpired:
                phase = .failed("Sign in to this Memos server again, then retry.", signIn: true)
            case MoeMemosError.invalidStatusCode(403, _), MoeMemosError.invalidStatusCode(404, _):
                phase = .failed("This memo was deleted or your account can’t access it.", signIn: false)
            case MoeMemosError.invalidParams:
                phase = .failed("This memo ID is invalid for your Memos server.", signIn: false)
            default:
                phase = .failed("Check your connection to the Memos server and try again.", signIn: false)
            }
        }
    }

    private func preview(_ memo: Memo, remote: any RemoteService, link: MemoLink) -> some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text(memo.renderTime())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                MemoCardContent(memo: memo, textSelectionEnabled: true, showsAttachments: false)
                ForEach(Array(memo.resources.enumerated()), id: \.offset) { _, resource in
                    if usesServerOrigin(resource.url, server: link.server) {
                        Attachment(resource: resource, remoteDownload: {
                            try await remote.download(url: resource.url, mimeType: resource.mimeType)
                        })
                    } else {
                        Attachment(resource: resource)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private func usesServerOrigin(_ url: URL, server: URL) -> Bool {
        guard let scheme = server.scheme, url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == server.host, url.user == nil, url.password == nil else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (url.port ?? defaultPort) == (server.port ?? defaultPort)
    }
}
