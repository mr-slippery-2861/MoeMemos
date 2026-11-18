import MapKit
import MemoData
import Models
import SwiftUI

struct MemosWorkspaceView: View {
    @Environment(AccountManager.self) private var accounts

    var body: some View {
        Group {
            if let service = accounts.currentRemoteService as? MemosWorkspaceService {
                MemosWorkspaceContents(service: service)
                    .id(accounts.currentAccount?.key)
            } else {
                ContentUnavailableView("Memos account required", systemImage: "network")
            }
        }
        .navigationTitle("Memos Workspace")
    }
}

@MainActor
private struct MemosWorkspaceContents: View {
    let service: any MemosWorkspaceService
    @State private var spaces: [MemosSpace] = []
    @State private var views: [SavedMemosView] = []
    @State private var supportsCollections = false
    @State private var selectedView: ViewEdit?
    @State private var showingNewSpace = false
    @State private var spaceTitle = ""
    @State private var spaceDescription = ""
    @State private var search = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            if supportsCollections {
                Section("Spaces") {
                    ForEach(spaces) { space in
                        NavigationLink {
                            MemosCollectionResults(
                                service: service, title: space.title, filter: "space == \"\(space.id)\"",
                                pageURL: service.webURL.appending(path: space.id)
                            )
                        } label: {
                            collectionLabel(space.title, emoji: space.emoji, icon: "person.2")
                        }
                    }
                    Button("New space", systemImage: "plus") {
                        spaceTitle = ""
                        spaceDescription = ""
                        showingNewSpace = true
                    }
                }
                Section("Saved views") {
                    ForEach(views) { saved in
                        NavigationLink {
                            MemosCollectionResults(service: service, title: saved.title, filter: saved.filter)
                        } label: {
                            collectionLabel(saved.title, emoji: saved.emoji, icon: "line.3.horizontal.decrease")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Edit", systemImage: "pencil") { selectedView = ViewEdit(saved) }
                                .tint(.accentColor)
                        }
                    }
                    Button("New saved view", systemImage: "plus") { selectedView = ViewEdit() }
                }
                Section("Browse") {
                    NavigationLink {
                        MemosCalendarView(service: service)
                    } label: {
                        Label("Calendar", systemImage: "calendar")
                    }
                    NavigationLink {
                        MemosCollectionResults(service: service, title: "Map", filter: "has_location", showMap: true)
                    } label: {
                        Label("Map", systemImage: "map")
                    }
                }
                Section("Server search") {
                    TextField("CEL filter expression", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    NavigationLink("Run filter") {
                        MemosCollectionResults(service: service, title: "Server search", filter: search)
                    }
                    .disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("Memos on the web") {
                Link(destination: service.webURL) { Label("Open Memos", systemImage: "safari") }
                if supportsCollections {
                    Link(destination: service.webURL.appending(path: "attachments")) {
                        Label("Attachments", systemImage: "paperclip")
                    }
                    Link(destination: service.webURL.appending(path: "inbox")) {
                        Label("Inbox and invitations", systemImage: "tray")
                    }
                    Link(destination: service.webURL.appending(path: "setting")) {
                        Label("Server settings and import", systemImage: "gearshape")
                    }
                }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $selectedView, onDismiss: { Task { await reload() } }) { edit in
            NavigationStack { MemosSavedViewEditor(service: service, edit: edit) }
        }
        .alert("New space", isPresented: $showingNewSpace) {
            TextField("Title", text: $spaceTitle)
            TextField("Description", text: $spaceDescription)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createSpace() } }
                .disabled(spaceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Memos Workspace", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func collectionLabel(_ title: String, emoji: String?, icon: String) -> some View {
        if let emoji, !emoji.isEmpty {
            Label { Text(title) } icon: { Text(emoji) }
        } else {
            Label(title, systemImage: icon)
        }
    }

    private func createSpace() async {
        do {
            try await service.createSpace(title: spaceTitle, description: spaceDescription)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() async {
        do {
            supportsCollections = try await service.supportsCollections()
            guard supportsCollections else { return }
            async let nextSpaces = service.listSpaces()
            async let nextViews = service.listSavedViews()
            (spaces, views) = try await (nextSpaces, nextViews)
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

private struct ViewEdit: Identifiable {
    let id = UUID()
    let existing: SavedMemosView?

    init(_ existing: SavedMemosView? = nil) {
        self.existing = existing
    }
}

@MainActor
private struct MemosSavedViewEditor: View {
    let service: any MemosWorkspaceService
    let edit: ViewEdit
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var filter = ""
    @State private var busy = false
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Title", text: $title)
            TextField("CEL filter expression", text: $filter, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if edit.existing != nil {
                Button("Delete saved view", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(edit.existing == nil ? "New saved view" : "Edit saved view")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await perform { try await service.saveView(id: edit.existing?.id, title: title, filter: filter) } }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            title = edit.existing?.title ?? ""
            filter = edit.existing?.filter ?? ""
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .confirmationDialog("Delete saved view?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let id = edit.existing?.id else { return }
                Task { await perform { try await service.deleteView(id: id) } }
            }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await operation()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct MemosCollectionResults: View {
    let service: any MemosWorkspaceService
    let title: String
    let filter: String
    var pageURL: URL?
    var showMap = false
    @State private var mapSelection: String?
    @State private var results: [Memo] = []
    @State private var nextPage: String?
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if showMap, !results.isEmpty {
                Map(selection: $mapSelection) {
                    ForEach(results, id: \.remoteId) { memo in
                        if let location = memo.location, location.isValid, let id = memo.remoteId {
                            Marker(location.placeholder.isEmpty ? memo.renderTime() : location.placeholder,
                                   coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
                                .tag(id)
                        }
                    }
                }
                .frame(minHeight: 240)
            }
            ForEach(visibleResults, id: \.remoteId) { memo in
                VStack(alignment: .leading, spacing: 8) {
                    Text(memo.renderTime()).font(.footnote).foregroundStyle(.secondary)
                    MemoCardContent(memo: memo, toggleTaskItem: nil)
                    if let name = memo.remoteId {
                        Link(destination: service.webURL.appending(path: name)) {
                            Label("Open in Memos", systemImage: "safari")
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if !loading && results.isEmpty && errorMessage == nil {
                ContentUnavailableView("No memos", systemImage: "note.text")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("Retry") { Task { await load(append: nextPage != nil) } }
            }
            if loading {
                ProgressView()
            } else if nextPage != nil && errorMessage == nil {
                Button("Load more") { Task { await load(append: true) } }
            }
        }
        .navigationTitle(title)
        .toolbar {
            if let pageURL {
                Link(destination: pageURL) { Label("Manage space in Memos", systemImage: "safari") }
            }
        }
        .task { await load(append: false) }
        .refreshable { await load(append: false) }
    }

    private var visibleResults: [Memo] {
        guard showMap, let mapSelection else { return results }
        return results.filter { $0.remoteId == mapSelection }
    }

    private func load(append: Bool) async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let page = try await service.listMemos(filter: filter, pageToken: append ? nextPage : nil)
            guard !Task.isCancelled else { return }
            if !append {
                results = []
                mapSelection = nil
            }
            var seen = Set(results.compactMap(\.remoteId))
            results += page.list.filter { memo in
                guard let id = memo.remoteId else { return false }
                return seen.insert(id).inserted
            }
            nextPage = page.nextPageToken
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

@MainActor
private struct MemosCalendarView: View {
    let service: any MemosWorkspaceService
    @State private var date = Date.now

    var body: some View {
        VStack {
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .frame(maxWidth: 430)
            if let day = Calendar.current.dateInterval(of: .day, for: date) {
                MemosCollectionResults(service: service, title: "Calendar", filter: filter(day))
                    .id(day.start)
            }
        }
        .navigationTitle("Calendar")
    }

    private func filter(_ day: DateInterval) -> String {
        let style = Date.ISO8601FormatStyle()
        let start = day.start.formatted(style)
        let end = day.end.formatted(style)
        return "created_ts >= timestamp(\"\(start)\") && created_ts < timestamp(\"\(end)\")"
    }
}
