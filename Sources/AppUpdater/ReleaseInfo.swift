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
        guard let a = versionParts(candidate), let b = versionParts(current) else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : "0", y = index < b.count ? b[index] : "0"
            if x.count != y.count { return x.count > y.count }
            if x != y { return x > y }
        }
        return false
    }

    /// Invalid values must never compare equal at the installation trust boundary.
    static func versionsMatch(_ first: String, _ second: String) -> Bool {
        guard versionParts(first) != nil, versionParts(second) != nil else { return false }
        return !isNewer(first, than: second) && !isNewer(second, than: first)
    }

    private static func versionParts(_ text: String) -> [String]? {
        let value = (text.first == "v" || text.first == "V") ? text.dropFirst() : text[...]
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        // Compare decimal strings so a malformed oversized component cannot overflow Int and become zero.
        return parts.map { let digits = $0.drop { $0 == "0" }; return digits.isEmpty ? "0" : String(digits) }
    }

    /// Reads GitHub's release JSON. Prefers the versioned `<Name>-<version>.dmg` asset over the stable `assetName`.
    /// Drafts and prereleases are ignored, and only downloads from github.com over https are accepted.
    public static func parse(_ data: Data, assetName: String) -> ReleaseInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["draft"] as? Bool) != true, (root["prerelease"] as? Bool) != true,
              let tag = root["tag_name"] as? String else { return nil }
        guard versionParts(tag) != nil else { return nil }
        let version = String((tag.first == "v" || tag.first == "V") ? tag.dropFirst() : tag[...])
        let assets = (root["assets"] as? [[String: Any]]) ?? []
        func url(_ name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        let base = (assetName as NSString).deletingPathExtension
        let ext = (assetName as NSString).pathExtension
        guard let download = url("\(base)-\(version).\(ext)") ?? url(assetName),
              download.scheme == "https", download.host == "github.com",
              download.user == nil, download.password == nil, download.port == nil || download.port == 443 else { return nil }
        let page = (root["html_url"] as? String).flatMap(URL.init(string:)).flatMap { url in
            url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
                && (url.port == nil || url.port == 443) ? url : nil
        }
        let date = (root["published_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return ReleaseInfo(
            version: version,
            notes: ((root["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            downloadURL: download,
            pageURL: page,
            date: date
        )
    }
}
