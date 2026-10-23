import Foundation
import XCTest
@testable import AppUpdater

final class ZIPArchiveTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "UpdaterZIP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A tiny stored ZIP fixture, including Unix mode bits for link and special-file regressions.
    private func zip(_ entries: [(String, Data, UInt32)], at url: URL) throws {
        func number(_ value: UInt32, bytes: Int) -> Data {
            Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
        func crc(_ data: Data) -> UInt32 {
            var value: UInt32 = 0xffff_ffff
            for byte in data {
                value ^= UInt32(byte)
                for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 1 ? 0xedb8_8320 : 0) }
            }
            return value ^ 0xffff_ffff
        }
        var result = Data(), central = Data()
        for (path, contents, mode) in entries {
            let name = Data(path.utf8), size = UInt32(contents.count), checksum = crc(contents), offset = UInt32(result.count)
            result += number(0x04034b50, bytes: 4) + number(20, bytes: 2) + number(0, bytes: 2) + number(0, bytes: 2)
            result += number(0, bytes: 4) + number(checksum, bytes: 4) + number(size, bytes: 4) + number(size, bytes: 4)
            result += number(UInt32(name.count), bytes: 2) + number(0, bytes: 2) + name + contents
            central += number(0x02014b50, bytes: 4) + number(0x0314, bytes: 2) + number(20, bytes: 2)
            central += number(0, bytes: 4) + number(0, bytes: 4) + number(checksum, bytes: 4) + number(size, bytes: 4) + number(size, bytes: 4)
            central += number(UInt32(name.count), bytes: 2) + number(0, bytes: 2) + number(0, bytes: 2)
            central += number(0, bytes: 4) + number(mode << 16, bytes: 4) + number(offset, bytes: 4) + name
        }
        let centralOffset = UInt32(result.count)
        result += central
        result += number(0x06054b50, bytes: 4) + number(0, bytes: 4)
        result += number(UInt32(entries.count), bytes: 2) + number(UInt32(entries.count), bytes: 2)
        result += number(UInt32(central.count), bytes: 4) + number(centralOffset, bytes: 4) + number(0, bytes: 2)
        try result.write(to: url)
    }

    private func extract(_ entries: [(String, Data, UInt32)]) async throws -> URL {
        let root = try scratch(), archive = root.appending(path: "update.zip"), output = root.appending(path: "out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try zip(entries, at: archive)
        try await ZIPArchive.extract(archive, to: output)
        return output
    }

    func testExtractsWrappedAppAndRetainsInternalFrameworkSymlink() async throws {
        let out = try await extract([
            ("Release/Test.app/Contents/Frameworks/F.framework/Versions/A/F", Data("signed content".utf8), 0o100755),
            ("Release/Test.app/Contents/Frameworks/F.framework/Versions/Current", Data("A".utf8), 0o120777),
        ])
        let app = try XCTUnwrap(UpdateInstaller.findApp(in: out, named: "Test.app"))
        try ZIPArchive.validateContents(in: app)
        XCTAssertEqual(try String(contentsOf: app.appending(path: "Contents/Frameworks/F.framework/Versions/Current/F"), encoding: .utf8), "signed content")
    }

    func testRejectsDuplicateNamedAppsInSeparateWrappers() throws {
        let root = try scratch()
        for wrapper in ["A", "B"] {
            try FileManager.default.createDirectory(at: root.appending(path: "\(wrapper)/Test.app"), withIntermediateDirectories: true)
        }
        XCTAssertNil(UpdateInstaller.findApp(in: root, named: "Test.app"))
    }

    func testParentTraversalCannotWriteOutsideExtractionRoot() async throws {
        let root = try scratch(), archive = root.appending(path: "update.zip"), output = root.appending(path: "out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try zip([("../escaped", Data("bad".utf8), 0o100644)], at: archive)
        do { try await ZIPArchive.extract(archive, to: output); XCTFail("must refuse traversal") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "escaped").path))
    }

    func testSymlinkCannotRedirectExtractionOutsideRoot() async throws {
        let root = try scratch(), archive = root.appending(path: "update.zip"), output = root.appending(path: "out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try zip([("link", Data("..".utf8), 0o120777), ("link/escaped", Data("bad".utf8), 0o100644)], at: archive)
        do { try await ZIPArchive.extract(archive, to: output); XCTFail("must refuse redirected extraction") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "escaped").path))
    }

    func testAppCannotLinkToSiblingPayloadInTheArchive() async throws {
        let out = try await extract([
            ("payload", Data("outside app".utf8), 0o100644),
            ("Test.app/escape", Data("../payload".utf8), 0o120777),
        ])
        let app = try XCTUnwrap(UpdateInstaller.findApp(in: out, named: "Test.app"))
        XCTAssertThrowsError(try ZIPArchive.validateContents(in: app))
    }

    func testRejectsSpecialFilesAndHardlinksBeforeStaging() throws {
        let root = try scratch()
        let file = root.appending(path: "a")
        try Data("data".utf8).write(to: file)
        try FileManager.default.linkItem(at: file, to: root.appending(path: "b"))
        XCTAssertThrowsError(try ZIPArchive.validateContents(in: root))
        try FileManager.default.removeItem(at: root.appending(path: "b"))
        XCTAssertEqual(mkfifo(root.appending(path: "pipe").path, 0o600), 0)
        XCTAssertThrowsError(try ZIPArchive.validateContents(in: root))
    }

    func testRejectsTruncatedAndOversizedDirectoriesBeforeExtracting() throws {
        let root = try scratch(), archive = root.appending(path: "update.zip")
        try zip([("file", Data("data".utf8), 0o100644)], at: archive)
        var bytes = try Data(contentsOf: archive)
        let central = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        // Claim an expanded size above 2 GiB without allocating a giant fixture.
        bytes.replaceSubrange((central.lowerBound + 24)..<(central.lowerBound + 28), with: [0xff, 0xff, 0xff, 0x7f])
        // Two entries are unnecessary: 0x80000001 alone exceeds the limit.
        bytes[central.lowerBound + 24] = 1
        bytes[central.lowerBound + 27] = 0x80
        try bytes.write(to: archive)
        XCTAssertThrowsError(try ZIPArchive.validateDirectory(in: archive))
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: archive)
        XCTAssertThrowsError(try ZIPArchive.validateDirectory(in: archive))
    }

    func testReleaseSelectsTheVersionedNativeZIP() throws {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v1.2", "assets": [
            ["name": "Test-1.2-\(arch).zip", "browser_download_url": "https://github.com/a/b/Test-1.2-\(arch).zip"],
            ["name": "Test.zip", "browser_download_url": "https://github.com/a/b/Test.zip"],
        ]])
        XCTAssertEqual(ReleaseInfo.parse(data, assetName: "Test.zip")?.downloadURL.lastPathComponent, "Test-1.2-\(arch).zip")
    }

    func testRejectsDecoyDirectoryBeforeThePhysicalZIPDirectory() throws {
        let root = try scratch(), archive = root.appending(path: "update.zip")
        try zip([("file", Data("data".utf8), 0o100644)], at: archive)
        let original = try Data(contentsOf: archive)
        let start = try XCTUnwrap(original.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
        let end = original.count - 22
        var decoy = Data(original[start..<end])
        decoy.replaceSubrange(24..<28, with: [1, 0, 0, 0])
        // The declared offset points at the decoy; libarchive's SFX correction would read the real
        // directory adjacent to EOCD instead. Accounting must require that exact physical position.
        let forged = Data(original[..<start]) + decoy + Data(original[start...])
        try forged.write(to: archive)
        XCTAssertThrowsError(try ZIPArchive.validateDirectory(in: archive))
    }

    @MainActor func testLivePublishedZIPsVerifyWithoutInstalling() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPUPDATER_LIVE"] == "1")
        for name in ["StatBar", "PowerBar", "Tweaks", "UpdateBar"] {
            let root = try scratch()
            let data = try await liveReleaseData(repository: "erikrole/\(name)")
            let release = try XCTUnwrap(ReleaseInfo.parse(data, assetName: "\(name).zip"), name)
            let configuration = AppUpdater.Configuration(repository: "erikrole/\(name)", assetName: "\(name).zip",
                bundleIdentifier: "com.erole.\(name)", appURL: root.appending(path: "\(name).app"), currentVersion: "0")
            let prepared = try await UpdateInstaller.prepare(release: release, destination: configuration.appURL, configuration: configuration) { _ in }
            defer {
                try? FileManager.default.removeItem(at: prepared.staged)
                try? FileManager.default.removeItem(at: prepared.workDirectory)
                withExtendedLifetime(prepared.lease) {}
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.staged.path))
        }
    }
}
