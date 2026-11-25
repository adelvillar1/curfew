import Foundation

/// The one outbound network call in Curfew (D28).
///
/// It lives in its own file because the project's invariant is "no network path" and the test that
/// enforces it now allows exactly this file and nothing else. Keeping the carve-out to a single named
/// file means a second socket appearing anywhere else still fails the build.
public struct JevHTTPTransport: JevTransport {
    public var url: URL
    public var apiKey: String
    public var timeout: TimeInterval

    public init(url: URL, apiKey: String, timeout: TimeInterval = 30) {
        self.url = url
        self.apiKey = apiKey
        self.timeout = timeout
    }

    public func post(_ body: Data) throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Cloudflare fronts this host and answers 403 / error 1010 to urllib-shaped clients —
        // measured twice on this machine. A plain product name is enough.
        request.setValue("curfew", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var result: Result<(Int, Data), Error>?
        }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.result = .success((status, data ?? Data()))
        }.resume()
        semaphore.wait()

        switch box.result {
        case .success(let pair): return pair
        case .failure(let error): throw error
        case nil: throw JevError.transport("no response")
        }
    }
}
