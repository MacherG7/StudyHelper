import Foundation
import StudyAI
import StudyData

/// One log entry reduced to what the totals need.
struct LogUsage: Equatable {
    var date: Date
    var providerName: String
    var model: String
    var task: String
    var inputTokens: Int
    var outputTokens: Int
    var costEUR: Double
    var costUSD: Double
    /// False when the price was unknown (the cost is not part of the sums).
    var costKnown: Bool

    init(
        date: Date, providerName: String, model: String, task: String, inputTokens: Int = 0, outputTokens: Int = 0,
        costEUR: Double = 0, costUSD: Double = 0, costKnown: Bool = true
    ) {
        self.date = date
        self.providerName = providerName
        self.model = model
        self.task = task
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costEUR = costEUR
        self.costUSD = costUSD
        self.costKnown = costKnown
    }

    init(_ log: RequestLog) {
        self.init(
            date: log.date, providerName: log.providerName, model: log.model, task: log.task,
            inputTokens: log.inputTokens ?? 0, outputTokens: log.outputTokens ?? 0, costEUR: log.costEUR ?? 0,
            costUSD: log.costUSD ?? 0, costKnown: log.costKnown)
    }
}

/// Sum over a set of requests.
struct UsageSum: Equatable {
    var requests = 0
    var inputTokens = 0
    var outputTokens = 0
    var costEUR = 0.0
    var costUSD = 0.0
    /// Requests without a known price (their cost is missing from the sum).
    var unknownCostRequests = 0

    mutating func add(_ usage: LogUsage) {
        requests += 1
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        if usage.costKnown {
            costEUR += usage.costEUR
            costUSD += usage.costUSD
        } else {
            unknownCostRequests += 1
        }
    }
}

/// Totals of one day or month, overall and by provider, model and task.
struct PeriodTotals: Identifiable, Equatable {
    var id: Date { start }
    var start: Date
    var total = UsageSum()
    var byProvider: [String: UsageSum] = [:]
    var byModel: [String: UsageSum] = [:]
    var byTask: [String: UsageSum] = [:]
}

enum RequestLogTotals {
    enum Period { case day, month }

    /// Newest period first.
    static func totals(
        _ usages: [LogUsage], by period: Period, calendar: Calendar = .current
    ) -> [PeriodTotals] {
        var result: [Date: PeriodTotals] = [:]
        for usage in usages {
            let components: Set<Calendar.Component> = period == .day ? [.year, .month, .day] : [.year, .month]
            let start = calendar.date(from: calendar.dateComponents(components, from: usage.date)) ?? usage.date
            var totals = result[start] ?? PeriodTotals(start: start)
            totals.total.add(usage)
            totals.byProvider[usage.providerName, default: UsageSum()].add(usage)
            totals.byModel[usage.model, default: UsageSum()].add(usage)
            totals.byTask[AITask(rawValue: usage.task)?.germanName ?? usage.task, default: UsageSum()].add(usage)
            result[start] = totals
        }
        return result.values.sorted { $0.start > $1.start }
    }
}
