//
//  MemosList.swift
//  MoeMemos
//
//  Created by Mudkip on 2022/9/4.
//

import MemoData
import SwiftUI
import SwiftData
import Account
import Models
import Env
import MemoKit
import DesignSystem

struct MemosList: View {
    let tag: Tag?

    private static let pageSize = 40
    @State private var searchString = ""
    @State private var visibleLimit = Self.pageSize
    @State private var filterResult: FilterResult?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppPath.self) private var appPath
    @Environment(AccountManager.self) private var accountManager
    @Environment(AccountViewModel.self) var userState: AccountViewModel
    @Environment(MemosViewModel.self) private var memosViewModel: MemosViewModel
    @State private var manualSyncAlertMessage: String?
    @State private var showingManualSyncAlert = false
    @State private var showingHigherV1SyncConfirmation = false
    @State private var hasDraft = false

    private struct FilterRequest: Equatable {
        let accountKey: String?
        let revision: Int
        let tag: Tag?
        let searchString: String

        var isActive: Bool { tag != nil || !searchString.isEmpty }
    }

    private struct FilterResult {
        let request: FilterRequest
        let memoIDs: Set<PersistentIdentifier>
    }

    private struct SearchEntry: Sendable {
        let id: PersistentIdentifier
        let content: String
    }
    
    var body: some View {
        let defaultMemoVisibility = userState.currentUser?.defaultVisibility ?? .private
        let request = FilterRequest(accountKey: accountManager.currentAccount?.key, revision: memosViewModel.memoListRevision,
                                    tag: tag, searchString: searchString)
        let matchingIDs = filterResult?.request == request ? filterResult?.memoIDs : nil
        let memoList = memosViewModel.memoList
        let isFiltering = request.isActive && matchingIDs == nil
        let filteredMemoList = isFiltering ? [] : orderedMemos(memoList, matchingIDs: matchingIDs)
        let visibleMemos = filteredMemoList.prefix(visibleLimit)
        let canSync = ((try? memosViewModel.service) as? SyncableService) != nil
        let isFirstLoad = !memosViewModel.inited && memoList.isEmpty
        
        ZStack(alignment: .bottomTrailing) {
            if let error = memosViewModel.loadError, memosViewModel.memoList.isEmpty {
                ContentUnavailableView {
                    Label("common.load-failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("common.retry") { Task { try? await memosViewModel.loadMemos() } }
                }
            } else if isFirstLoad || isFiltering {
                ProgressView("common.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredMemoList.isEmpty {
                if !searchString.isEmpty {
                    ContentUnavailableView {
                        Label("search.no-results", systemImage: "magnifyingglass")
                    } description: {
                        Text(searchString)
                    } actions: {
                        Button("search.clear") { searchString = "" }
                    }
                } else {
                    ContentUnavailableView {
                        Label(LocalizedStringKey(tag == nil ? "memo.memos.empty" : "memo.tag.empty"), systemImage: "note.text")
                    } description: {
                        Text(LocalizedStringKey(tag == nil ? "memo.empty.description" : "memo.tag.empty.description"))
                    } actions: {
                        Button(LocalizedStringKey(hasDraft ? "input.continue-draft" : "input.compose")) {
                            appPath.presentedSheet = .newMemo
                        }
                    }
                }
            } else {
                List {
                    if hasDraft && tag == nil && searchString.isEmpty {
                        Section {
                            Button {
                                appPath.presentedSheet = .newMemo
                            } label: {
                                Label("input.continue-draft", systemImage: "square.and.pencil")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                        }
                    }

                    ForEach(visibleMemos, id: \.id) { item in
                        Section {
                            if #available(iOS 26, *) {
                                NavigationLink(value: Route.memo(item.id)) {
                                    MemoCard(item, defaultMemoVisibility: defaultMemoVisibility)
                                }
                                .navigationLinkIndicatorVisibility(.hidden)
                            } else {
                                MemoCard(item, defaultMemoVisibility: defaultMemoVisibility)
                                    .onTapGesture {
                                        appPath.navigationRequest = .push(.memo(item.id))
                                    }
                            }
                        }
                        .onAppear {
                            if item.id == visibleMemos.last?.id && visibleLimit == visibleMemos.count
                                && visibleMemos.count < filteredMemoList.count {
                                visibleLimit += Self.pageSize
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
            }
            
            if #unavailable(iOS 26.0) {
                Button {
                    appPath.presentedSheet = .newMemo
                } label: {
                    Circle().overlay {
                        Image(systemName: "plus")
                            .resizable()
                            .frame(width: 25, height: 25)
                            .foregroundColor(.white)
                    }
                    .shadow(radius: 1)
                    .frame(width: 60, height: 60)
                }
                .accessibilityLabel(Text(LocalizedStringKey(hasDraft ? "input.continue-draft" : "input.compose")))
                .padding(20)
            }
        }
        .task(id: accountManager.currentAccount?.key) {
            visibleLimit = Self.pageSize
            refreshDraftAvailability()
        }
        .task(id: request) {
            guard request.isActive else {
                filterResult = nil
                return
            }
            do {
                if !request.searchString.isEmpty {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                let entries = memosViewModel.memoList.map { SearchEntry(id: $0.id, content: $0.content) }
                let matches = try await Self.matchingIDs(in: entries, tag: request.tag, searchString: request.searchString)
                try Task.checkCancellation()
                filterResult = FilterResult(request: request, memoIDs: matches)
            } catch {
                // A newer query or a different account superseded this request.
            }
        }
        .onChange(of: searchString) { _, _ in
            visibleLimit = Self.pageSize
        }
        .onChange(of: tag) { _, _ in
            visibleLimit = Self.pageSize
        }
        .onChange(of: appPath.presentedSheet) { _, sheet in
            if sheet == nil { refreshDraftAvailability() }
        }
        .toolbar {
            if canSync {
                ToolbarItem(placement: .topBarTrailing) {
                    SyncStatusBadge(syncing: memosViewModel.syncing, unsyncedCount: memoList.count(where: { $0.syncState != .synced })) {
                        triggerManualSync()
                    }
                }
            }
            if #available(iOS 26.0, *) {
                DefaultToolbarItem(kind: .search, placement: horizontalSizeClass == .regular ? .topBarTrailing : .bottomBar)
                    .prioritizeVisibility()
                if horizontalSizeClass != .regular {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                }
                ToolbarItem(placement: horizontalSizeClass == .regular ? .topBarTrailing : .bottomBar) {
                    Button {
                        appPath.presentedSheet = .newMemo
                    } label: {
                        Label(LocalizedStringKey(hasDraft ? "input.continue-draft" : "input.compose"), systemImage: "square.and.pencil")
                    }
                }
                .prioritizeVisibility()
            }
        }
        .searchable(text: $searchString)
        .compactSearchToolbar()
        .navigationTitle(tag?.name ?? NSLocalizedString("memo.memos", comment: "Memos"))
        .alert(NSLocalizedString("sync.failed.title", comment: "Manual sync failed alert title"), isPresented: $showingManualSyncAlert) {
            Button(NSLocalizedString("common.ok", comment: "OK button label"), role: .cancel) {}
        } message: {
            Text(manualSyncAlertMessage ?? NSLocalizedString("Unknown error.", comment: ""))
        }
        .confirmationDialog(NSLocalizedString("compat.continue-sync.title", comment: "Higher version sync confirmation title"), isPresented: $showingHigherV1SyncConfirmation, titleVisibility: .visible) {
            Button(NSLocalizedString("common.cancel", comment: "Cancel button label"), role: .cancel) {}
            Button(NSLocalizedString("compat.action.still-sync", comment: "Force sync button label")) {
                triggerManualSync(forceHigherV1VersionSync: true)
            }
        } message: {
            Text(manualSyncAlertMessage ?? moeMemosHigherMemosVersionSyncWarning)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshDraftAvailability()
            Task {
                if memosViewModel.inited {
                    try? await memosViewModel.loadMemos()
                }
            }
        }
    }

    private func refreshDraftAvailability() {
        guard let accountKey = accountManager.currentAccount?.key else {
            hasDraft = false
            return
        }
        hasDraft = MemoDraftStore.hasNewMemoDraft(
            defaults: UserDefaults(suiteName: AppInfo.groupContainerIdentifier) ?? .standard,
            accountKey: accountKey
        )
    }

    private func triggerManualSync(forceHigherV1VersionSync: Bool = false) {
        Task {
            do {
                try await memosViewModel.syncNow(trigger: .manual, forceHigherV1VersionSync: forceHigherV1VersionSync)
            } catch let error as ManualSyncCompatibilityError {
                switch error {
                case .unsupportedVersion:
                    manualSyncAlertMessage = error.localizedDescription
                    showingManualSyncAlert = true
                case .higherV1VersionNeedsConfirmation(version: _):
                    manualSyncAlertMessage = error.localizedDescription
                    showingHigherV1SyncConfirmation = true
                }
            } catch {
                manualSyncAlertMessage = error.localizedDescription
                showingManualSyncAlert = true
            }
        }
    }
    
    private func orderedMemos(_ memoList: [StoredMemo], matchingIDs: Set<PersistentIdentifier>?) -> [StoredMemo] {
        var pinned: [StoredMemo] = []
        var unpinned: [StoredMemo] = []
        for memo in memoList where matchingIDs?.contains(memo.id) ?? true {
            if memo.pinned {
                pinned.append(memo)
            } else {
                unpinned.append(memo)
            }
        }
        return pinned + unpinned
    }

    @concurrent
    private static func matchingIDs(in entries: [SearchEntry], tag: Tag?, searchString: String) async throws -> Set<PersistentIdentifier> {
        var matches = Set<PersistentIdentifier>()
        for entry in entries {
            try Task.checkCancellation()
            if !searchString.isEmpty && !entry.content.localizedCaseInsensitiveContains(searchString) { continue }
            if let tag, !MemoTagExtractor.extract(from: entry.content).contains(where: tag.matches) { continue }
            matches.insert(entry.id)
        }
        return matches
    }
}
