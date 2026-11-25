import Foundation

/// The outbound call Curfew makes, kept as its own seam.
///
/// There is no "no network" rule any more (D29 — this is a tool for one person, not something shipped
/// to a store). It stays in its own file for two reasons that survive that ruling: the tests inject a
/// fake transport and never dial out, and the diagnostic path is asserted not to depend on this layer,
/// so `list` / `why` / `doctor` keep working with no network and no key.
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

        // No URL cache: the decision log is the cache that matters, and a sandboxed run cannot write
        // ~/Library/Caches/curfew anyway — URLSession logged a page of noise about it.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)

        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var result: Result<(Int, Data), Error>?
        }
        let box = Box()
        session.dataTask(with: request) { data, response, error in
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
