import Foundation

/// A per-app list of public stable releases. Entries use the GitHub release shape so
/// both discovery paths use the same asset selection and version rules.
enum StableReleaseFeed {
    static func newest(_ data: Data, repository: String, assetName: String, tagPrefix: String?,
                       systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> ReleaseInfo? {
        guard data.count <= 512 * 1024,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let currentOS = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
        return entries.compactMap { entry -> ReleaseInfo? in
            guard let minimum = entry["minimum_macos"] as? String,
                  ReleaseInfo.versionsMatch(minimum, minimum), !ReleaseInfo.isBeta(minimum),
                  !ReleaseInfo.isNewer(minimum, than: currentOS),
                  let release = ReleaseInfo.parse(entry, assetName: assetName, allowPrerelease: false, tagPrefix: tagPrefix),
                  let tag = entry["tag_name"] as? String, release.archiveSHA256 != nil,
                  release.downloadURL.query == nil, release.downloadURL.fragment == nil,
                  release.downloadURL.pathComponents.dropFirst().dropLast().joined(separator: "/")
                    .caseInsensitiveCompare("\(repository)/releases/download/\(tag)") == .orderedSame else { return nil }
            return release
        }.max { ReleaseInfo.isNewer($1.version, than: $0.version) }
    }

    static func fetch(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "raw.githubusercontent.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.query == nil, url.fragment == nil else { throw URLError(.unsupportedURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 8))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 512 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
