import Foundation

/// A published release of the app, read from GitHub's "latest release" JSON.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: String
    /// The release body (Markdown), shown in the update window.
    public let notes: String
    public let downloadURL: URL
    public let pageURL: URL?
    public let date: Date?

    public init(version: String, notes: String, downloadURL: URL, pageURL: URL? = nil, date: Date? = nil) {
        self.version = version
        self.notes = notes
        self.downloadURL = downloadURL
        self.pageURL = pageURL
        self.date = date
    }

    /// "1.4.0" > "1.3.1"; missing parts count as 0 and a leading "v" is ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.drop { $0 == "v" || $0 == "V" }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Reads GitHub's release JSON. Prefers the versioned `<Name>-<version>.dmg` asset over the stable `assetName`.
    /// Drafts and prereleases are ignored, and only downloads from github.com over https are accepted.
    public static func parse(_ data: Data, assetName: String) -> ReleaseInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["draft"] as? Bool) != true, (root["prerelease"] as? Bool) != true,
              let tag = root["tag_name"] as? String else { return nil }
        let version = String(tag.drop { $0 == "v" || $0 == "V" })
        guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let assets = (root["assets"] as? [[String: Any]]) ?? []
        func url(_ name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        let base = (assetName as NSString).deletingPathExtension
        let ext = (assetName as NSString).pathExtension
        guard let download = url("\(base)-\(version).\(ext)") ?? url(assetName),
              download.scheme == "https", download.host == "github.com" else { return nil }
        let date = (root["published_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return ReleaseInfo(
            version: version,
            notes: ((root["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            downloadURL: download,
            pageURL: (root["html_url"] as? String).flatMap(URL.init(string:)),
            date: date
        )
    }
}
