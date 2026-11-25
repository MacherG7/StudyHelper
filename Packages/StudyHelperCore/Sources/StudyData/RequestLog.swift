import Foundation
import StudyCore
import SwiftData

// Request log (SPEC §10). StudyData does not know StudyAI: the app converts its response metadata into a plain
// `RequestLogEntry`. Everything that is only shown in the developer mode (raw prompt/response, reasoning text, tool
// calls, learning units) goes into `detailData` as opaque JSON produced by the app.

public enum SchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        SchemaV1.models + [RequestLog.self]
    }

    @Model
    public final class RequestLog {
        @Attribute(.unique) public var id: UUID
        public var date: Date
        /// `AITask` raw value.
        public var task: String
        /// `ProviderKind` raw value.
        public var providerKind: String
        public var providerName: String
        public var model: String
        public var reasoning: String?
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheReadTokens: Int?
        public var cacheWriteTokens: Int?
        public var reasoningTokens: Int?
        public var duration: Double
        public var timeToFirstToken: Double?
        public var costUSD: Double?
        public var costEUR: Double?
        /// False when no price was known (cost columns are then nil and shown as "unbekannt").
        public var costKnown: Bool
        public var sentText: Bool
        public var sentImage: Bool
        public var toolCallCount: Int
        public var parsingError: String?
        /// Set for failed requests (they are logged too).
        public var errorMessage: String?
        /// Opaque JSON from the app (raw request/response, reasoning, tool calls, learning units).
        @Attribute(.externalStorage) public var detailData: Data

        public init(entry: RequestLogEntry) {
            id = entry.id
            date = entry.date
            task = entry.task
            providerKind = entry.providerKind
            providerName = entry.providerName
            model = entry.model
            reasoning = entry.reasoning
            inputTokens = entry.inputTokens
            outputTokens = entry.outputTokens
            cacheReadTokens = entry.cacheReadTokens
            cacheWriteTokens = entry.cacheWriteTokens
            reasoningTokens = entry.reasoningTokens
            duration = entry.duration
            timeToFirstToken = entry.timeToFirstToken
            costUSD = entry.costUSD
            costEUR = entry.costEUR
            costKnown = entry.costKnown
            sentText = entry.sentText
            sentImage = entry.sentImage
            toolCallCount = entry.toolCallCount
            parsingError = entry.parsingError
            errorMessage = entry.errorMessage
            detailData = entry.detailJSON
        }
    }
}

public typealias RequestLog = SchemaV2.RequestLog

/// Plain input for `StudyRepository.addRequestLog`.
public struct RequestLogEntry: Sendable, Hashable {
    public var id: UUID
    public var date: Date
    public var task: String
    public var providerKind: String
    public var providerName: String
    public var model: String
    public var reasoning: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var reasoningTokens: Int?
    public var duration: Double
    public var timeToFirstToken: Double?
    public var costUSD: Double?
    public var costEUR: Double?
    public var costKnown: Bool
    public var sentText: Bool
    public var sentImage: Bool
    public var toolCallCount: Int
    public var parsingError: String?
    public var errorMessage: String?
    /// Opaque JSON object produced by the app.
    public var detailJSON: Data

    public init(
        id: UUID = UUID(), date: Date = Date(), task: String, providerKind: String, providerName: String,
        model: String, reasoning: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil, reasoningTokens: Int? = nil,
        duration: Double = 0, timeToFirstToken: Double? = nil, costUSD: Double? = nil, costEUR: Double? = nil,
        costKnown: Bool = false, sentText: Bool = false, sentImage: Bool = false, toolCallCount: Int = 0,
        parsingError: String? = nil, errorMessage: String? = nil, detailJSON: Data = Data("{}".utf8)
    ) {
        self.id = id
        self.date = date
        self.task = task
        self.providerKind = providerKind
        self.providerName = providerName
        self.model = model
        self.reasoning = reasoning
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.duration = duration
        self.timeToFirstToken = timeToFirstToken
        self.costUSD = costUSD
        self.costEUR = costEUR
        self.costKnown = costKnown
        self.sentText = sentText
        self.sentImage = sentImage
        self.toolCallCount = toolCallCount
        self.parsingError = parsingError
        self.errorMessage = errorMessage
        self.detailJSON = detailJSON
    }
}

extension StudyRepository {
    @discardableResult
    public func addRequestLog(_ entry: RequestLogEntry) throws -> RequestLog {
        let log = RequestLog(entry: entry)
        context.insert(log)
        if context.hasChanges { try context.save() }
        return log
    }

    /// Newest first.
    public func requestLogs(limit: Int? = nil) throws -> [RequestLog] {
        var descriptor = FetchDescriptor<RequestLog>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        if let limit { descriptor.fetchLimit = limit }
        return try context.fetch(descriptor)
    }

    public func deleteAllRequestLogs() throws {
        try context.delete(model: RequestLog.self)
        if context.hasChanges { try context.save() }
    }

    /// All logs, newest first, as a JSON array. The detail data is embedded as JSON (not base64); if it is not
    /// valid JSON it is exported as text under `detailText`.
    public func exportRequestLogsJSON() throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let items: [[String: Any]] = try requestLogs().map { log in
            var item: [String: Any] = [
                "id": log.id.uuidString, "date": iso.string(from: log.date), "task": log.task,
                "providerKind": log.providerKind, "providerName": log.providerName, "model": log.model,
                "duration": log.duration, "costKnown": log.costKnown, "sentText": log.sentText,
                "sentImage": log.sentImage, "toolCallCount": log.toolCallCount,
            ]
            let optionals: [(String, Any?)] = [
                ("reasoning", log.reasoning), ("inputTokens", log.inputTokens), ("outputTokens", log.outputTokens),
                ("cacheReadTokens", log.cacheReadTokens), ("cacheWriteTokens", log.cacheWriteTokens),
                ("reasoningTokens", log.reasoningTokens), ("timeToFirstToken", log.timeToFirstToken),
                ("costUSD", log.costUSD), ("costEUR", log.costEUR), ("parsingError", log.parsingError),
                ("errorMessage", log.errorMessage),
            ]
            for (key, value) in optionals { if let value { item[key] = value } }
            // URLs never leave the app with credentials or query (they could carry secrets).
            for key in ["errorMessage", "parsingError"] {
                if let text = item[key] as? String { item[key] = URLRedaction.redact(in: text) }
            }
            if var detail = (try? JSONSerialization.jsonObject(with: log.detailData)) as? [String: Any] {
                if var metadata = detail["metadata"] as? [String: Any], let raw = metadata["rawRequest"] as? String {
                    // The first line of the raw request is "METHOD URL".
                    var lines = raw.components(separatedBy: "\n")
                    if let first = lines.first { lines[0] = URLRedaction.redact(in: first) }
                    metadata["rawRequest"] = lines.joined(separator: "\n")
                    detail["metadata"] = metadata
                }
                item["detail"] = detail
            } else if let detail = try? JSONSerialization.jsonObject(with: log.detailData, options: [.fragmentsAllowed]) {
                item["detail"] = detail
            } else if let text = String(data: log.detailData, encoding: .utf8) {
                item["detailText"] = text
            }
            return item
        }
        return try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
    }
}
