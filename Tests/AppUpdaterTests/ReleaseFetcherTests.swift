import Foundation
import XCTest
@testable import AppUpdater

private let checkURL = URL(string: "https://api.github.com/repos/erikrole/fetch-releases/releases/latest")!
private let webPage = URL(string: "https://github.com/erikrole/fetch-releases/releases/tag/v1.5.8")!
private func reply(_ url: URL, _ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

/// Stub just the API. Web discovery and asset HEADs use the production ephemeral session/redirect delegate.
private final class LimitedAPIProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: reply(request.url!, 429, headers: ["X-RateLimit-Remaining": "0"]), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor Server {
    var requests: [URLRequest] = []
    let status: Int
    let page: URL
    let missing: Bool
    let stableOnly: Bool
    init(status: Int = 403, page: URL = webPage, missing: Bool = false, stableOnly: Bool = false) { self.status = status; self.page = page; self.missing = missing; self.stableOnly = stableOnly }
    func send(_ r: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(r)
        let url = r.url!
        if url.host == "api.github.com" { return (Data("{}".utf8), reply(url, status, headers: ["X-RateLimit-Remaining": "0"])) }
        if url.path.hasSuffix("/releases/latest") { return (Data(), reply(page, 200)) }
        let found = !missing && url.lastPathComponent == (stableOnly ? "Fetch.dmg" : "Fetch-1.5.8.dmg")
        return (Data(), reply(found ? URL(string: "https://release-assets.githubusercontent.com/test/asset")! : url, found ? 200 : 404))
    }
}

@MainActor final class ReleaseFetcherTests: XCTestCase {
    func testAPIResponseDoesNotProbeWeb() async throws {
        let server = Server(status: 200)
        let (data, status) = try await ReleaseFetcher.fetch(checkURL, assetName: "Fetch.dmg", userAgent: "Test") { try await server.send($0) }
        XCTAssertEqual(status, 200); XCTAssertEqual(data, Data("{}".utf8))
        let requests = await server.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(requests[0].httpShouldHandleCookies)
    }

    func testRateLimitUsesTagAnchoredVerifiedAssetAndKeepsCachedNotesEligible() async throws {
        for status in [403, 429] {
            let server = Server(status: status)
            let (data, code) = try await ReleaseFetcher.fetch(checkURL, assetName: "Fetch.dmg", userAgent: "Test") { try await server.send($0) }
            let release = try XCTUnwrap(ReleaseInfo.parse(data, assetName: "Fetch.dmg"))
            XCTAssertEqual(code, 200); XCTAssertEqual(release.version, "1.5.8")
            XCTAssertEqual(release.downloadURL.absoluteString, "https://github.com/erikrole/fetch-releases/releases/download/v1.5.8/Fetch-1.5.8.dmg")
            XCTAssertEqual(release.pageURL, webPage)
            XCTAssertTrue(release.notes.isEmpty); XCTAssertNil(release.date)
            let requests = await server.requests
            XCTAssertTrue(requests.dropFirst().allSatisfy { $0.httpMethod == "HEAD" })
            XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "Authorization") != nil })
        }
    }

    func testBadDiscoveryAndMissingAssetsStayFailures() async {
        let pages = ["https://github.com/another/repo/releases/tag/v1.5.8", "https://example.com/erikrole/fetch-releases/releases/tag/v1.5.8",
                     "http://github.com/erikrole/fetch-releases/releases/tag/v1.5.8", "https://github.com/erikrole/fetch-releases/releases/tag/v2.0-beta.1",
                     "https://github.com/erikrole/fetch-releases/releases/tag/v1.5.8?unexpected=1",
                     "https://github.com/erikrole/fetch-releases/releases/tag/v1..8"]
        for page in pages {
            let server = Server(page: URL(string: page)!)
            do { _ = try await ReleaseFetcher.fetch(checkURL, assetName: "Fetch.dmg", userAgent: "Test") { try await server.send($0) }; XCTFail(page) }
            catch { XCTAssertTrue(error.localizedDescription.contains("limited update checks")) }
        }
        let missing = Server(missing: true)
        do { _ = try await ReleaseFetcher.fetch(checkURL, assetName: "Fetch.dmg", userAgent: "Test") { try await missing.send($0) }; XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("limited update checks")) }
    }

    func testStableAssetFallbackAndExistingNotesCache() async throws {
        let server = Server(stableOnly: true)
        let (data, _) = try await ReleaseFetcher.fetch(checkURL, assetName: "Fetch.dmg", userAgent: "Test") { try await server.send($0) }
        let release = try XCTUnwrap(ReleaseInfo.parse(data, assetName: "Fetch.dmg"))
        XCTAssertEqual(release.downloadURL.lastPathComponent, "Fetch.dmg")
        let id = "AppUpdaterFallbackTests-" + UUID().uuidString
        let updater = AppUpdater(.init(repository: "erikrole/fetch-releases", assetName: "Fetch.dmg", bundleIdentifier: id), defaults: UserDefaults(suiteName: id)!)
        defer { try? FileManager.default.removeItem(at: updater.notesCache.directory) }
        updater.notesCache.save("Real release notes", version: release.version)
        XCTAssertEqual(updater.resolvedNotes(for: release), "Real release notes")
        let message = ReleaseFetcher.Failure.limited(nil).localizedDescription
        XCTAssertTrue(message.contains("limited update checks")); XCTAssertFalse(message.contains("online"))
    }

    func testNetworkFailureCancellationAndBetaQueryDoNotFallBack() async {
        do {
            _ = try await ReleaseFetcher.fetch(checkURL, assetName: "Fetch.dmg", userAgent: "Test") { _ in throw URLError(.secureConnectionFailed) }
            XCTFail()
        } catch { XCTAssertEqual((error as? URLError)?.code, .secureConnectionFailed) }
        let server = Server()
        let beta = URL(string: "https://api.github.com/repos/erikrole/fetch-releases/releases?per_page=20")!
        do { _ = try await ReleaseFetcher.fetch(beta, assetName: "Fetch.dmg", userAgent: "Test") { try await server.send($0) }; XCTFail() } catch {}
        let requests = await server.requests; XCTAssertEqual(requests.count, 1)
        do {
            _ = try await ReleaseFetcher.fetch(checkURL, assetName: "Fetch.dmg", userAgent: "Test") { request in
                if request.url?.host == "api.github.com" { return (Data(), reply(checkURL, 429)) }
                throw CancellationError()
            }
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLoginAndHTMLResponsesCannotCountAsAssets() async {
        for html in [false, true] {
            do {
                _ = try await ReleaseFetcher.fetch(checkURL, assetName: "Fetch.dmg", userAgent: "Test") { request in
                    let url = request.url!
                    if url.host == "api.github.com" { return (Data(), reply(checkURL, 429)) }
                    if url.path.hasSuffix("/latest") { return (Data(), reply(webPage, 200)) }
                    let target = URL(string: html ? "https://release-assets.githubusercontent.com/asset" : "https://github.com/login")!
                    return (Data(), reply(target, 200, headers: html ? ["Content-Type": "text/html"] : [:]))
                }
                XCTFail()
            } catch { XCTAssertTrue(error.localizedDescription.contains("limited update checks")) }
        }
    }

    func testRedirectsStayHTTPSAndProbesCannotBecomeDownloads() {
        var original = URLRequest(url: URL(string: "https://github.com/erikrole/fetch-releases/releases/latest")!)
        original.httpMethod = "HEAD"
        let changedMethod = URLRequest(url: webPage)
        XCTAssertEqual(ReleaseFetcher.redirected(changedMethod, original: original)?.httpMethod, "HEAD")
        XCTAssertNil(ReleaseFetcher.redirected(URLRequest(url: URL(string: "https://github.com/another/repo/releases/tag/v1.5.8")!), original: original))
        XCTAssertNil(ReleaseFetcher.redirected(URLRequest(url: URL(string: "http://github.com/erikrole/fetch-releases/releases/tag/v1.5.8")!), original: original))
        original.url = URL(string: "https://github.com/erikrole/fetch-releases/releases/download/v1.5.8/Fetch.dmg")!
        let cdn = URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/file")!)
        XCTAssertEqual(ReleaseFetcher.redirected(cdn, original: original)?.httpMethod, "HEAD")
        XCTAssertNil(ReleaseFetcher.redirected(URLRequest(url: URL(string: "https://example.com/file")!), original: original))
    }

    func testLiveFallbackWithoutAPIQuota() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPUPDATER_FALLBACK_LIVE"] == "1")
        let (data, _) = try await ReleaseFetcher.fetch(checkURL, assetName: "Fetch.dmg", userAgent: "AppUpdaterTests",
                                                     protocolClasses: [LimitedAPIProtocol.self])
        let release = try XCTUnwrap(ReleaseInfo.parse(data, assetName: "Fetch.dmg"))
        XCTAssertTrue(release.downloadURL.path.contains("/releases/download/"))
        XCTAssertEqual(release.pageURL?.host, "github.com")
    }
}
