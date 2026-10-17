import Foundation

/// Observes real source requests. Hosts must redact URLs before persistence;
/// no headers, response bodies or localized error messages are included.
public enum SourceNetworkDiagnostics {
    /// Host-owned opaque identifiers. They are never sent as HTTP headers.
    public struct Context: Sendable, Equatable {
        public let playbackID: UUID
        public let attemptID: UUID
        public init(playbackID: UUID, attemptID: UUID) {
            self.playbackID = playbackID
            self.attemptID = attemptID
        }
    }

    @TaskLocal public static var context: Context?
    private static let requestContextKey = "AetherEngine.SourceNetworkDiagnostics.context"

    static func request(_ request: URLRequest, context: Context?) -> URLRequest {
        let copy = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        if let context {
            URLProtocol.setProperty([context.playbackID.uuidString, context.attemptID.uuidString],
                                    forKey: requestContextKey, in: copy)
        } else {
            URLProtocol.removeProperty(forKey: requestContextKey, in: copy)
        }
        return copy as URLRequest
    }

    static func context(for request: URLRequest) -> Context? {
        guard let values = URLProtocol.property(forKey: requestContextKey, in: request) as? [String],
              values.count == 2, let playbackID = UUID(uuidString: values[0]),
              let attemptID = UUID(uuidString: values[1]) else { return nil }
        return Context(playbackID: playbackID, attemptID: attemptID)
    }

    public struct Event: Sendable {
        public let requestID: UUID
        public let role: String
        public let phase: String
        public let originalURL: URL?
        public let url: URL?
        public let status: Int?
        public let urlErrorCode: Int?
        public let bytes: Int64
        public let elapsedMilliseconds: Int
        public var dnsMilliseconds: Int?
        public var connectMilliseconds: Int?
        public var tlsMilliseconds: Int?
        public var responseMilliseconds: Int?
        public var reusedConnection: Bool?
        public var context: Context? = nil
    }

    public static var handler: (@Sendable (Event) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return observer }
        set { lock.lock(); observer = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var observer: (@Sendable (Event) -> Void)?

    static func urlErrorCode(_ error: Error?) -> Int? {
        var next = error as NSError?
        for _ in 0..<8 {
            guard let current = next else { return nil }
            if current.domain == NSURLErrorDomain { return current.code }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    final class Trace: Sendable {
        private let id = UUID()
        private let role: String
        private let start = ProcessInfo.processInfo.systemUptime
        private let context: Context?
        init(role: String, context: Context? = SourceNetworkDiagnostics.context) {
            self.role = role
            self.context = context
        }

        func record(_ phase: String, originalURL: URL, url: URL, status: Int? = nil,
                    bytes: Int64 = 0, error: Error? = nil) {
            handler?(Event(requestID: id, role: role, phase: phase,
                           originalURL: originalURL, url: url, status: status,
                           urlErrorCode: urlErrorCode(error), bytes: bytes,
                           elapsedMilliseconds: Int(max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000),
                           context: context))
        }

        private func event(_ phase: String, task: URLSessionTask, url: URL? = nil,
                           status: Int? = nil, error: Error? = nil) -> Event {
            Event(requestID: id, role: role, phase: phase,
                  originalURL: task.originalRequest?.url, url: url ?? task.currentRequest?.url,
                  status: status ?? (task.response as? HTTPURLResponse)?.statusCode,
                  urlErrorCode: urlErrorCode(error), bytes: task.countOfBytesReceived,
                  elapsedMilliseconds: Int(max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000),
                  context: context)
        }
        func response(task: URLSessionTask, response: URLResponse) {
            handler?(event("response", task: task, url: response.url, status: (response as? HTTPURLResponse)?.statusCode))
        }
        func redirect(task: URLSessionTask, response: HTTPURLResponse, request: URLRequest) {
            handler?(event("redirect", task: task, url: request.url, status: response.statusCode))
        }
        func completed(task: URLSessionTask, error: Error?, phase: String = "completed") {
            handler?(event(phase, task: task, error: error))
        }
        func metrics(task: URLSessionTask, metrics: URLSessionTaskMetrics) {
            guard let receive = handler else { return }
            func milliseconds(_ start: Date?, _ end: Date?) -> Int? {
                guard let start, let end else { return nil }
                return Int(max(0, end.timeIntervalSince(start)) * 1_000)
            }
            for transaction in metrics.transactionMetrics {
                var value = event("metrics", task: task, url: transaction.request.url,
                                  status: (transaction.response as? HTTPURLResponse)?.statusCode)
                value.dnsMilliseconds = milliseconds(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
                value.connectMilliseconds = milliseconds(transaction.connectStartDate, transaction.connectEndDate)
                value.tlsMilliseconds = milliseconds(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
                value.responseMilliseconds = milliseconds(transaction.requestStartDate, transaction.responseStartDate)
                value.reusedConnection = transaction.isReusedConnection
                receive(value)
            }
        }
    }
}
