import Foundation

/// Public release checks must also work when a shared network exhausts GitHub's anonymous API quota.
enum ReleaseFetcher {
    typealias Sender = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static func fetch(_ url: URL, assetName: String, userAgent: String,
                      protocolClasses: [AnyClass]? = nil) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await fetch(url, assetName: assetName, userAgent: userAgent) { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            return (data, response)
        }
    }

    static func fetch(_ url: URL, assetName: String, userAgent: String, send: Sender) async throws -> (Data, Int) {
        try Task.checkCancellation()
        func request(_ url: URL, method: String = "GET") -> URLRequest {
            var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            r.httpMethod = method
            r.httpShouldHandleCookies = false
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if method == "GET" { r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
            return r
        }
        let (data, response) = try await send(request(url))
        if response.statusCode == 200 { return (data, 200) }
        let failure = Failure.response(response)
        // A public /latest redirect is stable-only. Never substitute it for a beta/list query.
        guard [403, 429].contains(response.statusCode),
              url.scheme == "https", url.host == "api.github.com", url.query == nil,
              url.pathComponents.count == 6, url.pathComponents[1] == "repos",
              url.pathComponents[4] == "releases", url.pathComponents[5] == "latest",
              url.pathComponents[2...3].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              assetName == (assetName as NSString).lastPathComponent,
              !assetName.contains("\\"), ["dmg", "zip"].contains((assetName as NSString).pathExtension.lowercased())
        else { throw failure }
        let owner = url.pathComponents[2], repository = url.pathComponents[3]
        let base = URL(string: "https://github.com/\(owner)/\(repository)/releases")!
        do {
            let (_, latest) = try await send(request(base.appendingPathComponent("latest"), method: "HEAD"))
            guard latest.statusCode == 200, let page = latest.url,
                  trusted(page, hosts: ["github.com"]), page.query == nil, page.fragment == nil,
                  page.pathComponents.count == 6,
                  Array(page.pathComponents[1...4]) == [owner, repository, "releases", "tag"] else { throw failure }
            let tag = page.lastPathComponent
            let version = String((tag.first == "v" || tag.first == "V") ? tag.dropFirst() : tag[...])
            guard !version.isEmpty, version.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { throw failure }
            let name = (assetName as NSString).deletingPathExtension, ext = (assetName as NSString).pathExtension
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let candidates = ["\(name)-\(version)-\(architecture).\(ext)", "\(name)-\(version)-universal.\(ext)",
                              "\(name)-\(version).\(ext)", "\(name)-\(architecture).\(ext)", assetName]
            for candidate in candidates {
                try Task.checkCancellation()
                let asset = base.appendingPathComponent("download").appendingPathComponent(tag).appendingPathComponent(candidate)
                let (_, probe) = try await send(request(asset, method: "HEAD"))
                if probe.statusCode == 404 { continue }
                guard probe.statusCode == 200, let final = probe.url,
                      trusted(final, hosts: ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]),
                      final.host != "github.com" || (final.path == asset.path && final.query == nil),
                      probe.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/html") != true else { throw failure }
                // Use the existing parser and installer trust boundary. Normalizing the asset name also supports older hosts.
                let release: [String: Any] = ["tag_name": tag, "draft": false, "prerelease": false,
                    "html_url": page.absoluteString,
                    "body": "",
                    "assets": [["name": assetName, "browser_download_url": asset.absoluteString]]]
                return (try JSONSerialization.data(withJSONObject: release), 200)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw error }
        catch { throw failure }
        throw failure
    }

    private static func trusted(_ url: URL, hosts: Set<String>) -> Bool {
        url.scheme == "https" && hosts.contains(url.host ?? "") && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    static func redirected(_ request: URLRequest, original: URLRequest) -> URLRequest? {
        guard let url = request.url, let origin = original.url else { return nil }
        let discovery = original.httpMethod == "HEAD" && origin.path.hasSuffix("/releases/latest")
        let hosts: Set<String> = discovery ? ["github.com"]
            : (origin.host == "api.github.com" ? ["api.github.com"] : ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"])
        guard trusted(url, hosts: hosts) else { return nil }
        if discovery {
            guard url.pathComponents.count >= 3,
                  Array(url.pathComponents.prefix(3)) == Array(origin.pathComponents.prefix(3)) else { return nil }
        }
        var result = request
        if original.httpMethod == "HEAD" { result.httpMethod = "HEAD"; result.httpBody = nil }
        return result
    }

    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(task.originalRequest.flatMap { ReleaseFetcher.redirected(request, original: $0) })
        }
    }

    enum Failure: LocalizedError {
        case invalidResponse, limited(Date?), http(Int)
        static func response(_ response: HTTPURLResponse) -> Failure {
            if response.statusCode == 429 || (response.statusCode == 403 && response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
                    .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                return .limited(reset)
            }
            return .http(response.statusCode)
        }
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "GitHub returned an unreadable update response. Try again later."
            case .limited(let reset):
                let retry = reset.map { " Try again after " + DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) + "." } ?? " Try again later."
                return "GitHub has temporarily limited update checks from this network." + retry + " You can still view releases on GitHub."
            case .http(let code): return "GitHub couldn't provide the update information (HTTP \(code)). Try again later."
            }
        }
    }
}
