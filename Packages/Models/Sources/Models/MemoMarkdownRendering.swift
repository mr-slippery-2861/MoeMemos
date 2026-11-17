import Markdown

/// Bounds the number of hosted views that a selectable text view lays out at once.
public enum MemoMarkdownRendering {
    private static let attachmentLimit = 8

    public static func documents(in document: Document) -> [Document] {
        guard attachmentCount(in: document) > attachmentLimit else { return [document] }

        var documents: [Document] = []
        var blocks: [Markup] = []
        var attachments = 0
        for block in document.children {
            for part in listParts(of: block) {
                let count = attachmentCount(in: part)
                if !blocks.isEmpty && attachments + count > attachmentLimit {
                    documents.append(document.withUncheckedChildren(blocks) as! Document)
                    blocks = []
                    attachments = 0
                }
                blocks.append(part)
                attachments += count
            }
        }
        if !blocks.isEmpty { documents.append(document.withUncheckedChildren(blocks) as! Document) }
        return documents
    }

    /// A rendered segment retains its original source ranges, including inside lists.
    public static func togglingTask(_ item: ListItem, in document: Document) -> Document? {
        guard item.checkbox != nil, let range = item.range else { return nil }
        var rewriter = TaskRewriter(range: range)
        let result = rewriter.visit(document) as? Document
        return rewriter.didToggle ? result : nil
    }

    private static func listParts(of block: Markup) -> [Markup] {
        guard block is OrderedList || block is UnorderedList,
              attachmentCount(in: block) > attachmentLimit else { return [block] }

        var parts: [Markup] = []
        var items: [Markup] = []
        var attachments = 0
        var offset = 0
        for item in block.children {
            let count = attachmentCount(in: item)
            if !items.isEmpty && attachments + count > attachmentLimit {
                parts.append(listPart(block, items: items, offset: offset))
                offset += items.count
                items = []
                attachments = 0
            }
            items.append(item)
            attachments += count
        }
        if !items.isEmpty { parts.append(listPart(block, items: items, offset: offset)) }
        return parts
    }

    private static func listPart(_ list: Markup, items: [Markup], offset: Int) -> Markup {
        let part = list.withUncheckedChildren(items)
        if var ordered = part as? OrderedList, let original = list as? OrderedList {
            ordered.startIndex = original.startIndex + UInt(offset)
            return ordered
        }
        return part
    }

    private static func attachmentCount(in markup: Markup) -> Int {
        if markup is Table || markup is BlockQuote || markup is CodeBlock || markup is HTMLBlock
            || markup is Image || markup is BlockDirective || markup is ThematicBreak {
            return 1
        }
        let checkbox = (markup as? ListItem)?.checkbox == nil ? 0 : 1
        return markup.children.reduce(checkbox) { $0 + attachmentCount(in: $1) }
    }
}

private struct TaskRewriter: MarkupRewriter {
    let range: SourceRange
    private(set) var didToggle = false

    mutating func visitListItem(_ item: ListItem) -> Markup? {
        guard item.range == range, let checkbox = item.checkbox else { return defaultVisit(item) }
        var updated = item
        updated.checkbox = checkbox == .checked ? .unchecked : .checked
        didToggle = true
        return updated
    }
}
