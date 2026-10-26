import Foundation

/// A published release of the app, read from GitHub's "latest release" JSON.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: String
    /// The release body (Markdown), shown in the update window.
    public let notes: String
    public let downloadURL: URL
    public let pageURL: URL?
    public let date: Date?
    /// True for a GitHub prerelease or a `-beta.N` version. Only the beta channel ever sees these.
    public let isPrerelease: Bool

    public init(version: String, notes: String, downloadURL: URL, pageURL: URL? = nil, date: Date? = nil, isPrerelease: Bool = false) {
        self.isPrerelease = isPrerelease
        self.version = version
        self.notes = notes
        self.downloadURL = downloadURL
        self.pageURL = pageURL
        self.date = date
    }

    /// "1.4.0" > "1.3.1"; missing parts count as 0 and a leading "v" is ignored. "1.5.0-beta.2" is newer than
    /// "1.5.0-beta.1" and older than "1.5.0".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = version(candidate), let b = version(current) else { return false }
        for index in 0..<max(a.parts.count, b.parts.count) {
            let x = index < a.parts.count ? a.parts[index] : "0", y = index < b.parts.count ? b.parts[index] : "0"
            if x.count != y.count { return x.count > y.count }
            if x != y { return x > y }
        }
        switch (a.beta, b.beta) {
        case (nil, .some): return true            // 1.5.0 is newer than 1.5.0-beta.N
        case (.some, nil): return false
        case let (x?, y?): return x.count != y.count ? x.count > y.count : x > y
        case (nil, nil): return false
        }
    }

    /// True for `X.Y.Z-beta.N`.
    public static func isBeta(_ version: String) -> Bool { Self.version(version)?.beta != nil }

    /// Invalid values must never compare equal at the installation trust boundary.
    static func versionsMatch(_ first: String, _ second: String) -> Bool {
        guard version(first) != nil, version(second) != nil else { return false }
        return !isNewer(first, than: second) && !isNewer(second, than: first)
    }

    /// Decimal parts of the release number and, for `-beta.N`, the beta number as a normalized decimal string.
    private static func version(_ text: String) -> (parts: [String], beta: String?)? {
        let value = (text.first == "v" || text.first == "V") ? text.dropFirst() : text[...]
        let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = pieces.first, pieces.count <= 2 else { return nil }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        func normalized(_ part: Substring) -> String { let digits = part.drop { $0 == "0" }; return digits.isEmpty ? "0" : String(digits) }
        var beta: String?
        if pieces.count == 2 {
            // Only "beta.N" is a version suffix; anything else is not a release number.
            let suffix = pieces[1].split(separator: ".", omittingEmptySubsequences: false)
            guard suffix.count == 2, suffix[0] == "beta", !suffix[1].isEmpty, suffix[1].utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            beta = normalized(suffix[1])
        }
        // Compare decimal strings so a malformed oversized component cannot overflow Int and become zero.
        return (parts.map(normalized), beta)
    }

    private static func versionParts(_ text: String) -> [String]? { version(text)?.parts }

    /// Reads GitHub's release JSON. Prefers a versioned native-architecture asset, then a versioned or stable asset.
    /// Drafts are always ignored. Prereleases and `-beta.N` versions are ignored unless `allowPrerelease` is set (the beta
    /// channel). Only downloads from github.com over https are accepted.
    public static func parse(_ data: Data, assetName: String, allowPrerelease: Bool = false) -> ReleaseInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(root, assetName: assetName, allowPrerelease: allowPrerelease)
    }

    /// The newest release in GitHub's `releases` list (an array) that has the asset. Drafts are skipped; prereleases count
    /// only with `allowPrerelease`. Order in the list does not matter: the highest version wins.
    public static func newest(inList data: Data, assetName: String, allowPrerelease: Bool) -> ReleaseInfo? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var best: ReleaseInfo?
        for item in list {
            guard let release = parse(item, assetName: assetName, allowPrerelease: allowPrerelease) else { continue }
            if best == nil || isNewer(release.version, than: best!.version) { best = release }
        }
        return best
    }

    static func parse(_ root: [String: Any], assetName: String, allowPrerelease: Bool) -> ReleaseInfo? {
        guard (root["draft"] as? Bool) != true,
              let tag = root["tag_name"] as? String else { return nil }
        guard version(tag) != nil else { return nil }
        let flaggedPrerelease = (root["prerelease"] as? Bool) == true
        let prerelease = flaggedPrerelease || isBeta(tag)
        guard allowPrerelease || !prerelease else { return nil }
        let version = String((tag.first == "v" || tag.first == "V") ? tag.dropFirst() : tag[...])
        let assets = (root["assets"] as? [[String: Any]]) ?? []
        func url(_ name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        let base = (assetName as NSString).deletingPathExtension
        let ext = (assetName as NSString).pathExtension
        guard ["dmg", "zip"].contains(ext.lowercased()) else { return nil }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let candidates = ["\(base)-\(version)-\(architecture).\(ext)", "\(base)-\(version)-universal.\(ext)",
                          "\(base)-\(version).\(ext)", "\(base)-\(architecture).\(ext)", assetName]
        guard let download = candidates.lazy.compactMap({ url($0) }).first,
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
            date: date,
            isPrerelease: prerelease
        )
    }
}
