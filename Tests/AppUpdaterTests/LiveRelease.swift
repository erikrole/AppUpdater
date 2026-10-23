import Foundation
import XCTest

/// Optional read-only authentication avoids shared API limits in opt-in live tests.
func liveReleaseData(repository: String) async throws -> Data {
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
    if let token = ProcessInfo.processInfo.environment["APPUPDATER_GITHUB_TOKEN"], !token.isEmpty {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw NSError(domain: "LiveRelease", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not fetch live release metadata for \(repository)."])
    }
    return data
}
