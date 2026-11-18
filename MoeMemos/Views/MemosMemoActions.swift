import Models
import SwiftUI

@MainActor
struct MemoReactionsRow: View {
    let service: any MemosWorkspaceService
    let memo: String
    @State private var available = false
    @State private var reactions: [MemoReaction] = []
    @State private var isWorking = false
    @State private var showingPicker = false
    @State private var emoji = ""
    @State private var errorMessage: String?

    private var groups: [(emoji: String, reactions: [MemoReaction])] {
        Dictionary(grouping: reactions, by: \.emoji)
            .map { (emoji: $0.key, reactions: $0.value) }
            .sorted { $0.emoji < $1.emoji }
    }

    var body: some View {
        Group {
            if available {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(groups, id: \.emoji) { group in
                            let mine = group.reactions.contains(where: \.isMine)
                            Button {
                                Task { await toggle(group.emoji) }
                            } label: {
                                Text("\(group.emoji) \(group.reactions.count)")
                            }
                            .tint(mine ? .accentColor : .secondary)
                            .buttonStyle(.bordered)
                            .accessibilityAddTraits(mine ? .isSelected : [])
                        }
                        Button("Add reaction", systemImage: "face.smiling") {
                            emoji = ""
                            showingPicker = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                    }
                    .disabled(isWorking)
                }
                .scrollIndicators(.hidden)
            }
        }
        .task {
            do {
                guard try await service.supportsCollections() else { return }
                reactions = try await service.listReactions(memo: memo)
                available = true
            } catch {
                // Memos remain readable while offline.
            }
        }
        .alert("Add reaction", isPresented: $showingPicker) {
            TextField("Emoji", text: $emoji)
            Button("Cancel", role: .cancel) {}
            Button("React") {
                let value = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await toggle(value) }
            }
            .disabled(emoji.trimmingCharacters(in: .whitespacesAndNewlines).count != 1)
        } message: {
            Text("Enter one emoji using the emoji keyboard.")
        }
        .alert("Couldn’t update reaction", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func toggle(_ emoji: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let existing = reactions.first { $0.emoji == emoji && $0.isMine }
            try await service.toggleReaction(memo: memo, emoji: emoji, existing: existing)
            reactions = try await service.listReactions(memo: memo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct MemoShareLinks: View {
    let service: any MemosWorkspaceService
    let memo: String
    @Environment(\.dismiss) private var dismiss
    @State private var links: [MemoShareLink] = []
    @State private var busy = false
    @State private var expires = true
    @State private var expiry = Date.now.addingTimeInterval(86400)
    @State private var pendingRevoke: MemoShareLink?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Toggle("Set expiration", isOn: $expires)
                if expires {
                    DatePicker("Expires", selection: $expiry, in: Date.now...)
                }
                Button("Create share link") {
                    Task { await refresh { try await service.createShareLink(memo: memo, expires: expires ? expiry : nil) } }
                }
            } header: {
                Text("Create link")
            } footer: {
                Text("Anyone with the link can read this memo until the link expires or you revoke it.")
            }
            Section("Existing links") {
                ForEach(links) { link in
                    VStack(alignment: .leading) {
                        ShareLink(item: link.url) { Label("Share link", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderless)
                        if let expiry = link.expiry {
                            Text(expiry.formatted()).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Revoke", role: .destructive) { pendingRevoke = link }
                    }
                }
                if !busy && links.isEmpty { Text("No share links").foregroundStyle(.secondary) }
            }
            if busy { ProgressView() }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("Share links")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .task { await refresh {} }
        .refreshable { await refresh {} }
        .confirmationDialog("Revoke this link?", isPresented: Binding(
            get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }
        ), titleVisibility: .visible, presenting: pendingRevoke) { link in
            Button("Revoke", role: .destructive) {
                Task { await refresh { try await service.revokeShareLink(memo: memo, share: link.id) } }
            }
        }
    }

    private func refresh(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await operation()
            links = try await service.listShareLinks(memo: memo)
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

@MainActor
struct MemoPlacementEditor: View {
    let service: any MemosWorkspaceService
    let memo: String
    let update: (String?, MemoVisibility) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var spaces: [MemosSpace] = []
    @State private var initialSpace: String?
    @State private var space: String?
    @State private var visibility: MemoVisibility = .private
    @State private var loaded = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if loaded {
                Picker("Space", selection: $space) {
                    Text("No space").tag(nil as String?)
                    if let initialSpace, !spaces.contains(where: { $0.id == initialSpace }) {
                        Text("Current space").tag(Optional(initialSpace))
                    }
                    ForEach(spaces) { space in
                        Text(space.title).tag(Optional(space.id))
                    }
                }
                Picker("Audience", selection: $visibility) {
                    ForEach(availableVisibilities, id: \.self) { visibility in
                        Text(visibility.title).tag(visibility)
                    }
                }
                if visibility == .space {
                    Text("Members of the selected space can read this memo.")
                        .foregroundStyle(.secondary)
                }
            } else if errorMessage == nil {
                ProgressView()
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("Space and audience")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!loaded)
            }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .onChange(of: space) {
            if space == nil && visibility == .space { visibility = .private }
        }
        .task {
            do {
                async let places = service.listSpaces()
                let placement = try await service.memoPlacement(memo: memo)
                spaces = try await places
                initialSpace = placement.space
                space = placement.space
                visibility = placement.visibility
                loaded = true
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    private var availableVisibilities: [MemoVisibility] {
        space == nil ? [.private, .local, .public] : [.private, .local, .public, .space]
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await update(space, visibility)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
