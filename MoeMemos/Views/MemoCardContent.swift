//
//  MemoCardContent.swift
//  MoeMemos
//
//  Created by Mudkip on 2023/3/26.
//

import SwiftUI
import MarkdownView
import Markdown
import Models
import MemoKit

@MainActor
struct MemoCardContent: View {
    private enum MemoResource: Identifiable {
        case images([any ResourcePresentable])
        case attachment(any ResourcePresentable)
        
        var id: String {
            switch self {
            case .images(let resources):
                return resources.map { resource in
                    if let stored = resource as? StoredResource {
                        return "\(stored.id)"
                    }
                    if let url = resource.url {
                        return url.absoluteString
                    }
                    return "\(resource.filename)|\(resource.createdAt.timeIntervalSince1970)"
                }.joined(separator: ",")
            case .attachment(let resource):
                if let stored = resource as? StoredResource {
                    return "\(stored.id)"
                }
                if let url = resource.url {
                    return url.absoluteString
                }
                return "\(resource.filename)|\(resource.createdAt.timeIntervalSince1970)"
            }
        }
    }

    let memo: any MemoPresentable
    let toggleTaskItem: ((String) -> Void)?
    let truncate: Bool
    let textSelectionEnabled: Bool
    let showsAttachments: Bool
    
    @Environment(\.colorScheme) var colorScheme
    @State private var cachedRawMarkdown: String
    @State private var cachedPreprocessedMarkdown: String
    @State private var truncated: Bool

    init(
        memo: any MemoPresentable,
        toggleTaskItem: ((String) -> Void)? = nil,
        truncate: Bool = false,
        textSelectionEnabled: Bool = false,
        showsAttachments: Bool = true
    ) {
        self.memo = memo
        self.toggleTaskItem = toggleTaskItem
        self.truncate = truncate
        self.textSelectionEnabled = textSelectionEnabled
        self.showsAttachments = showsAttachments
        let content = memo.content
        _cachedRawMarkdown = State(initialValue: content)
        let preprocessResult = MemoMarkdownPreprocessor.preprocess(content, truncate: truncate)
        _cachedPreprocessedMarkdown = State(initialValue: MemoTagMarkdownPreprocessor.preprocessForDisplay(preprocessResult.0))
        _truncated = State(initialValue: preprocessResult.1)
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            markdownContent
            
            if truncated {
                Text("memo.view-more")
                    .foregroundStyle(.tint)
            }
            
            if showsAttachments {
                ForEach(resources()) { content in
                    resourceView(for: content)
                }
            }
            if let location = memo.location, location.isValid {
                MemoLocationView(location: location)
            }
        }
        .onChange(of: memo.content) { _, newContent in
            guard newContent != cachedRawMarkdown else {
                return
            }
            cachedRawMarkdown = newContent
            let preprocessResult = MemoMarkdownPreprocessor.preprocess(newContent, truncate: self.truncate)
            cachedPreprocessedMarkdown = MemoTagMarkdownPreprocessor.preprocessForDisplay(preprocessResult.0)
            truncated = preprocessResult.1
        }
    }

    @ViewBuilder
    private var markdownContent: some View {
        if textSelectionEnabled {
            MarkdownReader(cachedPreprocessedMarkdown) { parsed in
                let documents = MemoMarkdownRendering.documents(in: parsed.document)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(documents.indices, id: \.self) { index in
                        let segment = segment(parsed, document: documents[index])
                        MarkdownText(segment)
                            .markdownTaskListMarker { listItem in
                                taskListMarker(for: listItem, document: parsed.document)
                            }
                    }
                }
            }
        } else {
            MarkdownView(cachedPreprocessedMarkdown)
                .markdownTaskListMarker { listItem in
                    taskListMarker(for: listItem)
                }
        }
    }

    private func segment(_ parsed: MarkdownParseResult, document: Markdown.Document) -> MarkdownParseResult {
        var segment = parsed
        segment.document = document
        return segment
    }

    private func taskListMarker(for listItem: ListItem, document: Markdown.Document? = nil) -> some View {
        Button {
            if let document {
                guard let updated = MemoMarkdownRendering.togglingTask(listItem, in: document) else { return }
                toggleTaskItem?(MemoTagMarkdownPreprocessor.restoreRawMarkdown(updated.format()))
            } else {
                toggleTaskItem?(toggledMarkdown(for: listItem))
            }
        } label: {
            Image(systemName: listItem.checkbox == .checked ? "checkmark.square.fill" : "square")
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
        }
        .buttonStyle(.borderless)
        .disabled(truncated || toggleTaskItem == nil)
        .accessibilityLabel(Text("memo.checklist-item"))
        .accessibilityValue(Text(LocalizedStringKey(listItem.checkbox == .checked ? "memo.checked" : "memo.unchecked")))

    }
    
    @ViewBuilder
    private func resourceView(for content: MemoResource) -> some View {
        switch content {
        case .images(let urls):
            MemoCardImageView(media: urls)
        case .attachment(let resource):
            Attachment(resource: resource)
        }
    }

    private func resources() -> [MemoResource] {
        var attachments = [MemoResource]()
        let resourceList = memo.attachments
        let imageResources = resourceList.filter { resource in
            resource.mimeType.hasPrefix("image/") == true || resource.mimeType.hasPrefix("video/") == true
        }
        let otherResources = resourceList.filter { resource in
            !(resource.mimeType.hasPrefix("image/") == true) && !(resource.mimeType.hasPrefix("video/") == true)
        }
        
        if !imageResources.isEmpty {
            attachments.append(.images(imageResources))
        }
        
        attachments += otherResources.map { .attachment($0) }
        return attachments
    }

    private func toggledMarkdown(for listItem: ListItem) -> String {
        var node = listItem
        node.checkbox = listItem.checkbox == .checked ? .unchecked : .checked
        return MemoTagMarkdownPreprocessor.restoreRawMarkdown(node.root.format())
    }
}
