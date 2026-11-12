import AppUpdater
import Foundation

@main
struct ReleaseCheck {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 || arguments.count == 5 else {
            FileHandle.standardError.write(Data("Usage: swift run ReleaseCheck PREVIOUS.app CANDIDATE.zip VERSION [SHA256]\n".utf8))
            exit(2)
        }
        do {
            try await ReleaseVerification.check(previous: URL(filePath: arguments[1]), archive: URL(filePath: arguments[2]),
                                                version: arguments[3], sha256: arguments.count == 5 ? arguments[4] : nil)
            print("Verified the candidate, isolated swap, and rollback.")
        } catch {
            FileHandle.standardError.write(Data("Release verification failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
