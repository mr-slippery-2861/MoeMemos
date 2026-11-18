//
//  MemoView.swift
//  MoeMemos
//
//  Created by Mudkip on 2026/2/8.
//

import MemoSystem
import MemoData
import SwiftUI
import UniformTypeIdentifiers
import Models
import Env
import SwiftData
import Account
import DesignSystem

@MainActor
struct MemoView: View {
    let memoId: PersistentIdentifier

    @Environment(MemosViewModel.self) private var memosViewModel: MemosViewModel
    @Environment(AccountViewModel.self) private var accountViewModel: AccountViewModel
    @Environment(AccountManager.self) private var accountManager
    @Environment(AppPath.self) private var appPath
    @Environment(\.dismiss) private var dismiss

    @State private var canMoveToSpace = false
    @State private var showingPlacement = false
    @State private var showingShareLinks = false
    @State private var showingDeleteConfirmation = false
    @State private var commentsViewModel: MemoCommentsViewModel?

    private var commentsEnabled: Bool {
        accountManager.currentRemoteService is MemoCommentService && memo?.serverId != nil
    }

    var body: some View {
        Group {
            if let memo {
                ScrollView {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(memo.renderTime())
                                .font(.footnote)
                                .foregroundColor(.secondary)

                            if memo.visibility != accountViewModel.currentUser?.defaultVisibility {
                                Image(systemName: memo.visibility.iconName)
                                    .foregroundColor(.secondary)
                            }

                            if memo.pinned == true {
                                Image(systemName: "flag.fill")
                                    .renderingMode(.original)
                            }

                            if memo.syncState != .synced {
                                Image(systemName: syncIconName(for: memo.syncState))
                                    .imageScale(.small)
                                    .foregroundStyle(.orange)
                            }

                            Spacer()
                        }

                        MemoCardContent(
                            memo: memo,
                            toggleTaskItem: { updatedContent in
                                toggleTaskItem(updatedContent, for: memo)
                            },
                            textSelectionEnabled: true
                        )

                        if let service = accountManager.currentRemoteService as? MemosWorkspaceService,
                           let name = memo.serverId {
                            MemoReactionsRow(service: service, memo: name)
                                .id(name)
                        }

                        if commentsEnabled, let commentsViewModel {
                            Divider()

                            Text("memo.comments")
                                .font(.headline)

                            if commentsViewModel.comments.isEmpty && !commentsViewModel.loading {
                                Text("memo.comment.empty")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            } else {
                                MemoCommentsList(viewModel: commentsViewModel)
                            }
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .bottomAccessoryBar {
                    if commentsEnabled, let commentsViewModel {
                        MemoCommentComposer(sending: commentsViewModel.sending) { content in
                            try await commentsViewModel.sendComment(content: content)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Memo not found", systemImage: "note.text")
                    .task(id: memoId) {
                        try? await memosViewModel.loadMemos()
                    }
            }
        }
        .task(id: memo?.serverId) {
            guard commentsEnabled, commentsViewModel == nil, let serverId = memo?.serverId else { return }
            let viewModel = MemoCommentsViewModel(memoRemoteId: serverId)
            commentsViewModel = viewModel
            do {
                try await viewModel.loadComments()
            } catch {
                print(error)
            }
        }
        .task(id: accountManager.currentAccount?.key) {
            canMoveToSpace = false
            if let service = accountManager.currentRemoteService as? MemosWorkspaceService {
                let supported = (try? await service.supportsCollections()) == true
                if !Task.isCancelled { canMoveToSpace = supported }
            }
        }
        .navigationTitle(memo?.renderTime() ?? "Memo")
        .memoEntity(memo)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let memo {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        normalMenu(memo)
                    } label: {
                        Label("memo.actions", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .sheet(isPresented: $showingPlacement) {
            if let service = accountManager.currentRemoteService as? MemosWorkspaceService,
               let memo, let name = memo.serverId {
                NavigationStack {
                    MemoPlacementEditor(service: service, memo: name) { space, visibility in
                        guard memo.syncState == .synced, accountManager.currentAccount?.key == memo.accountKey else {
                            throw MoeMemosError.invalidParams
                        }
                        try await service.updateMemoPlacement(memo: name, space: space, visibility: visibility)
                        try? await memosViewModel.syncNow()
                    }
                }
            }
        }
        .sheet(isPresented: $showingShareLinks) {
            if let service = accountManager.currentRemoteService as? MemosWorkspaceService, let name = memo?.serverId {
                NavigationStack { MemoShareLinks(service: service, memo: name) }
            }
        }
        .confirmationDialog("memo.delete.confirm", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("memo.action.ok", role: .destructive) {
                Task {
                    guard let memo else {
                        return
                    }
                    try await memosViewModel.deleteMemo(id: memo.id)
                    dismiss()
                }
            }
            Button("memo.action.cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func normalMenu(_ memo: StoredMemo) -> some View {
        Button {
            Task {
                do {
                    try await memosViewModel.updateMemoOrganizer(id: memo.id, pinned: !(memo.pinned == true))
                } catch {
                    print(error)
                }
            }
        } label: {
            if memo.pinned == true {
                Label("memo.unpin", systemImage: "flag.slash")
            } else {
                Label("memo.pin", systemImage: "flag")
            }
        }
        Button {
            appPath.presentedSheet = .editMemo(memo.id)
        } label: {
            Label("memo.edit", systemImage: "pencil")
        }
        Button {
            UIPasteboard.general.setValue(memo.content, forPasteboardType: UTType.plainText.identifier)
        } label: {
            Label("memo.copy", systemImage: "doc.on.doc")
        }
        ShareLink(item: memo.content) {
            Label("memo.share", systemImage: "square.and.arrow.up")
        }
        if let account = accountManager.currentAccount, account.key == memo.accountKey,
           let serverID = memo.serverId, let link = MemoLink(account: account, memoID: serverID) {
            Button {
                UIPasteboard.general.string = link.url.absoluteString
            } label: {
                Label("Copy Moe Memos Link", systemImage: "link")
            }
        }
        if let service = accountManager.currentRemoteService as? MemosWorkspaceService,
           let name = memo.serverId {
            Link(destination: service.webURL.appending(path: name)) {
                Label("Edit rich text and Markup in Memos", systemImage: "safari")
            }
            if canMoveToSpace, memo.syncState == .synced {
                Button("Space and audience", systemImage: "person.2") { showingPlacement = true }
            }
            if memo.rowStatus == .normal && memo.visibility != .space {
                Button("Share links", systemImage: "link") { showingShareLinks = true }
            }
        }
        Button(role: .destructive, action: {
            Task {
                do {
                    try await memosViewModel.archiveMemo(id: memo.id)
                    dismiss()
                } catch {
                    print(error)
                }
            }
        }, label: {
            Label("memo.archive", systemImage: "archivebox")
        })
        Button(role: .destructive, action: {
            showingDeleteConfirmation = true
        }, label: {
            Label("memo.delete", systemImage: "trash")
        })
    }

    private func toggleTaskItem(_ updatedContent: String, for memo: StoredMemo) {
        let memoID = memo.id
        let visibility = memo.visibility
        let resourceIds = memo.orderedResources.filter { !$0.softDeleted }.map(\.id)

        Task {
            do {
                try await memosViewModel.editMemo(id: memoID, content: updatedContent, visibility: visibility, resources: resourceIds, tags: nil)
            } catch {
                print(error)
            }
        }
    }

    private func syncIconName(for state: SyncState) -> String {
        switch state {
        case .synced:
            return "checkmark.icloud"
        case .pendingCreate:
            return "plus.circle"
        case .pendingUpdate:
            return "arrow.triangle.2.circlepath"
        case .pendingDelete:
            return "trash"
        }
    }

    private var memo: StoredMemo? {
        if let memo = memosViewModel.memoList.first(where: { $0.id == memoId && !$0.softDeleted }) {
            return memo
        }
        return (try? memosViewModel.service)?.memo(id: memoId)
    }
}
