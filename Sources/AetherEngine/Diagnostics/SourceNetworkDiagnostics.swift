import Foundation

/// Observes real source requests. Hosts must redact URLs before persistence;
/// no headers, response bodies or localized error messages are included.
public enum SourceNetworkDiagnostics {
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
        init(role: String) { self.role = role }

        private func event(_ phase: String, task: URLSessionTask, url: URL? = nil,
                           status: Int? = nil, error: Error? = nil) -> Event {
            Event(requestID: id, role: role, phase: phase,
                  originalURL: task.originalRequest?.url, url: url ?? task.currentRequest?.url,
                  status: status ?? (task.response as? HTTPURLResponse)?.statusCode,
                  urlErrorCode: urlErrorCode(error), bytes: task.countOfBytesReceived,
                  elapsedMilliseconds: Int(max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000))
        }
        func response(task: URLSessionTask, response: URLResponse) {
            handler?(event("response", task: task, url: response.url, status: (response as? HTTPURLResponse)?.statusCode))
        }
        func redirect(task: URLSessionTask, response: HTTPURLResponse, request: URLRequest) {
            handler?(event("redirect", task: task, url: request.url, status: response.statusCode))
        }
        func completed(task: URLSessionTask, error: Error?) {
            handler?(event("completed", task: task, error: error))
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
