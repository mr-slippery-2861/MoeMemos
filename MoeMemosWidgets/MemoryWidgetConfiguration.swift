//
//  MemoryWidgetConfiguration.swift
//  MoeMemos
//
//  Created by Mudkip on 2024/11/24.
//

import MemoSystem
import Foundation
import AppIntents
import Models
import MemoData
import SwiftData

@available(iOS 17.0, macOS 14.0, watchOS 10.0, *)
struct MemoryWidgetConfiguration: AppIntent, WidgetConfigurationIntent, CustomIntentMigratedAppIntent {
    static let intentClassName = "MemoryWidgetConfigurationIntent"

    static let title: LocalizedStringResource = "Memory Widget Configuration"
    static let description = IntentDescription("Configurate how the memory widget is updated")

    @Parameter(title: "Update")
    var frequency: MemoryUpdatePeriodAppEnum?

    static var parameterSummary: some ParameterSummary {
        Summary()
    }

    func perform() async throws -> some IntentResult {
        // TODO: Place your refactored intent handler code here.
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, *)
struct PinnedMemoryWidgetConfiguration: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Pinned Memory Widget Configuration"
    static let description = IntentDescription("Select one memo to keep showing in this widget")

    @Parameter(title: "Update")
    var frequency: MemoryUpdatePeriodAppEnum?

    @Parameter(title: "Memo")
    var memo: MemoryWidgetMemoEntity?

    static var parameterSummary: some ParameterSummary {
        Summary()
    }

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, *)
struct MemoryWidgetMemoEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Memo"
    static let defaultQuery = MemoryWidgetMemoEntityQuery()

    let id: String
    let content: String
    let createdAt: Date

    var displayRepresentation: DisplayRepresentation {
        let title = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DisplayRepresentation(title: "\(title.prefix(50))")
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, *)
struct MemoryWidgetMemoEntityQuery: EntityQuery {
    func entities(for identifiers: [MemoryWidgetMemoEntity.ID]) async throws -> [MemoryWidgetMemoEntity] {
        try await MainActor.run {
            let store = MemoEntityStore(context: AppInfo().modelContext)
            return try identifiers.compactMap { id in
                guard let entity = try store.entity(forLegacyIdentifier: id) else { return nil }
                return MemoryWidgetMemoEntity(id: id, content: entity.content, createdAt: entity.createdAt)
            }
        }
    }

    func suggestedEntities() async throws -> [MemoryWidgetMemoEntity] {
        try await loadSuggestedEntitiesFromStore(limit: 100)
    }

    func defaultResult() async -> MemoryWidgetMemoEntity? {
        try? await loadSuggestedEntitiesFromStore(limit: 1).first
    }
}

@MainActor
private func loadSuggestedEntitiesFromStore(limit: Int) throws -> [MemoryWidgetMemoEntity] {
    let context = AppInfo().modelContext
    guard let accountKey = AccountManager(modelContext: context).currentUser?.accountKey else { return [] }
    var descriptor = FetchDescriptor<StoredMemo>(
        predicate: #Predicate { $0.accountKey == accountKey && !$0.softDeleted },
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    let batchSize = max(limit, 50)
    descriptor.fetchLimit = batchSize
    var results: [MemoryWidgetMemoEntity] = []
    // Row status is a Codable value, so check it after fetching each batch.
    while results.count < limit {
        try Task.checkCancellation()
        let batch = try context.fetch(descriptor)
        for memo in batch where memo.rowStatus == .normal {
            guard let token = PersistentIdentifierTokenCoder.encode(memo.id) else { continue }
            results.append(MemoryWidgetMemoEntity(id: token, content: memo.content, createdAt: memo.createdAt))
            if results.count == limit { return results }
        }
        guard batch.count == batchSize else { break }
        descriptor.fetchOffset = (descriptor.fetchOffset ?? 0) + batchSize
    }
    return results
}

@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
fileprivate extension IntentDialog {
    static func frequencyParameterDisambiguationIntro(count: Int, frequency: MemoryUpdatePeriodAppEnum) -> Self {
        "There are \(count) options matching ‘\(frequency)’."
    }
    static func frequencyParameterConfirmation(frequency: MemoryUpdatePeriodAppEnum) -> Self {
        "Just to confirm, you wanted ‘\(frequency)’?"
    }
}
