import Foundation

enum RemoteData {
    enum Failure: Error { case invalidURL, tooLarge }

    static func permits(_ url: URL?, hosts: Set<String>) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased(),
              hosts.contains(host), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let hosts: Set<String>
        init(hosts: Set<String>) { self.hosts = hosts }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(RemoteData.permits(request.url, hosts: hosts) ? request : nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    /// Check both advertised and actual decoded bytes, including chunked bodies.
    /// The task is cancelled on every exit, including limit/cancellation errors.
    static func load(_ request: URLRequest, maxBytes: Int, hosts: Set<String>,
                     session: URLSession = session) async throws -> (Data, URLResponse) {
        guard permits(request.url, hosts: hosts) else { throw Failure.invalidURL }
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectPolicy(hosts: hosts))
        defer { bytes.task.cancel() }
        guard permits(response.url, hosts: hosts) else { throw Failure.invalidURL }
        guard response.expectedContentLength <= Int64(maxBytes) else { throw Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBytes else { throw Failure.tooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}
