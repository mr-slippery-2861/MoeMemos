import SwiftUI
import Models
import MemoData
import DesignSystem

public struct Attachment: View {
    public let resource: any ResourcePresentable
    private let resourceManager: (any ResourceManager)?
    private let remoteDownload: (@MainActor () async throws -> URL)?
    @Environment(AccountManager.self) private var memosManager: AccountManager
    @Environment(\.openURL) private var openURL
    @State private var downloadedURL: URL?
    @State private var downloadError: Error?
    @State private var showingErrorToast = false
    @State private var downloading = false

    public init(resource: any ResourcePresentable, resourceManager: (any ResourceManager)? = nil,
                remoteDownload: (@MainActor () async throws -> URL)? = nil) {
        self.resource = resource
        self.resourceManager = resourceManager
        self.remoteDownload = remoteDownload
    }

    public var body: some View {
        let button = Button {
            Task {
                defer { downloading = false }
                do {
                    if let remoteDownload {
                        downloading = true
                        downloadedURL = try await remoteDownload()
                    } else if let stored = resource as? StoredResource {
                        downloading = true
                        if let localPath = stored.localPath, FileManager.default.fileExists(atPath: localPath) {
                            downloadedURL = URL(fileURLWithPath: localPath)
                        } else if let memos = memosManager.currentService {
                            downloadedURL = try await memos.ensureLocalResourceFile(id: stored.id)
                        }
                    } else if let url = resource.url {
                        // Non-local resources (e.g. Explore from other users) open directly in browser.
                        openURL(url)
                    } else {
                        throw MoeMemosError.invalidParams
                    }
                } catch {
                    showingErrorToast = true
                    downloadError = error
                }
            }
        } label: {
            HStack {
                if downloading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "paperclip")
                }
                Text(resource.filename)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(BorderlessButtonStyle())
        .disabled(downloading)
        .padding([.top, .bottom], 5)
        .toast(isPresenting: $showingErrorToast, alertType: .systemImage("xmark.circle", downloadError?.localizedDescription))
        .fullScreenCover(item: $downloadedURL) { url in
            QuickLookPreview(selectedURL: url, urls: [url])
                .edgesIgnoringSafeArea(.bottom)
                .background(TransparentBackground())
        }

        if resourceManager != nil, resource is StoredResource {
            button.contextMenu {
                menu()
            }
        } else {
            button
        }
    }

    @ViewBuilder
    func menu() -> some View {
        if let resourceManager, let storedResource = resource as? StoredResource {
            Button(role: .destructive, action: {
                Task {
                    try await resourceManager.deleteResource(id: storedResource.id)
                }
            }, label: {
                Label(resourceManager.removalLabel, systemImage: "trash")
            })
        }
    }
}
