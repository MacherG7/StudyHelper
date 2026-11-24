import Foundation

public struct SSEEvent: Sendable, Hashable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Server-Sent Events per the HTML spec: feed lines, get events. A blank line dispatches; comment lines (":") are
/// ignored; multiple `data:` lines are joined with "\n"; one leading space after the colon is removed.
public struct SSEParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    /// Feeds one line (without line terminator); returns an event when the line completes one.
    public mutating func feed(line rawLine: String) -> SSEEvent? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        default: break  // id, retry and unknown fields are not needed
        }
        return nil
    }

    /// End of stream: a pending event without the final blank line is still delivered.
    public mutating func finish() -> SSEEvent? { dispatch() }

    private mutating func dispatch() -> SSEEvent? {
        defer { eventName = nil; dataLines = [] }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }

    /// Turns a stream of lines into a stream of events.
    public static func events(
        from lines: AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await line in lines {
                        if let event = parser.feed(line: line) { continuation.yield(event) }
                    }
                    if let event = parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
