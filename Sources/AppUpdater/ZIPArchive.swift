import Foundation

/// Uses macOS's libarchive-backed extractor, whose default security policy refuses parent traversal and
/// extraction through directory symlinks. Never add -P/--absolute-paths or -U/--unlink-first.
enum ZIPArchive {
    static func extract(_ archive: URL, to directory: URL) async throws {
        try Task.checkCancellation()
        try validateDirectory(in: archive)
        // The extractor autodetects formats. A PK-prefixed TAR must not bypass ZIP size limits.
        let listing = try await UpdateInstaller.run("/usr/bin/env", ["LC_ALL=C", "/usr/bin/bsdtar", "-tvvf", archive.path])
        guard listing.status == 0,
              listing.output.split(separator: "\n").last(where: { $0.hasPrefix("Archive Format:") })?.hasPrefix("Archive Format: ZIP") == true else {
            throw UpdateInstaller.Failure(message: "The downloaded update isn't a supported ZIP archive.")
        }
        let result = try await UpdateInstaller.run("/usr/bin/bsdtar", ["-xf", archive.path, "-C", directory.path,
            "--safe-writes", "--no-same-owner", "--no-acls", "--no-fflags"])
        guard result.status == 0 else { throw UpdateInstaller.Failure(message: "Couldn't safely extract the downloaded ZIP.") }
        try validateContents(in: directory)
    }

    /// Bound extraction before invoking a tool. Path containment is enforced by bsdtar, independently of this
    /// central-directory accounting. Personal app releases do not need split, encrypted, or ZIP64 archives.
    static func validateDirectory(in archive: URL) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let signature = try handle.read(upToCount: 4)
        guard signature == Data([0x50, 0x4b, 0x03, 0x04]) || signature == Data([0x50, 0x4b, 0x05, 0x06]) else {
            throw UpdateInstaller.Failure(message: "The downloaded update isn't a ZIP archive.")
        }
        let size = try handle.seekToEnd()
        let tailSize = min(size, 65_557)
        try handle.seek(toOffset: size - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        func number(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | (UInt64(data[offset + $1]) << (8 * $1)) }
        }
        guard tail.count >= 22, let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            number(tail, $0, 4) == 0x06054b50 && number(tail, $0 + 20, 2) == UInt64(tail.count - $0 - 22)
        }) else { throw UpdateInstaller.Failure(message: "The ZIP directory is missing or incomplete.") }
        let count = number(tail, end + 10, 2), length = number(tail, end + 12, 4), offset = number(tail, end + 16, 4)
        guard number(tail, end + 4, 2) == 0, number(tail, end + 6, 2) == 0,
              number(tail, end + 8, 2) == count, count <= 60_000, length <= 16 * 1024 * 1024,
              offset != UInt32.max, offset + length == size - tailSize + UInt64(end) else {
            throw UpdateInstaller.Failure(message: "Split, ZIP64, or oversized update archives aren't supported.")
        }
        try handle.seek(toOffset: offset)
        let central = try handle.read(upToCount: Int(length)) ?? Data()
        guard central.count == Int(length) else { throw UpdateInstaller.Failure(message: "The ZIP directory is incomplete.") }
        var cursor = 0
        var expanded: UInt64 = 0
        for _ in 0..<count {
            guard cursor + 46 <= central.count, number(central, cursor, 4) == 0x02014b50 else {
                throw UpdateInstaller.Failure(message: "The ZIP directory is invalid.")
            }
            let bytes = number(central, cursor + 24, 4)
            expanded += bytes
            guard number(central, cursor + 8, 2) & 0x41 == 0, number(central, cursor + 34, 2) == 0,
                  bytes != UInt32.max, number(central, cursor + 20, 4) != UInt32.max,
                  number(central, cursor + 42, 4) != UInt32.max, expanded <= 2 * 1024 * 1024 * 1024 else {
                throw UpdateInstaller.Failure(message: "Encrypted, ZIP64, or oversized update archives aren't supported.")
            }
            let extraStart = cursor + 46 + Int(number(central, cursor + 28, 2))
            let extraEnd = extraStart + Int(number(central, cursor + 30, 2))
            cursor = extraEnd + Int(number(central, cursor + 32, 2))
            guard cursor <= central.count else { throw UpdateInstaller.Failure(message: "The ZIP directory is incomplete.") }
            var extra = extraStart
            while extra < extraEnd {
                guard extra + 4 <= extraEnd else { throw UpdateInstaller.Failure(message: "The ZIP metadata is incomplete.") }
                guard number(central, extra, 2) != 1 else { throw UpdateInstaller.Failure(message: "ZIP64 update archives aren't supported.") }
                extra += 4 + Int(number(central, extra + 2, 2))
                guard extra <= extraEnd else { throw UpdateInstaller.Failure(message: "The ZIP metadata is incomplete.") }
            }
        }
        guard cursor == central.count else { throw UpdateInstaller.Failure(message: "The ZIP directory has unsupported records.") }
    }

    /// Check without following links. A signed app must be self-contained, including framework symlinks.
    /// Reject special objects and hard links before ditto or signature tools can read them.
    static func validateContents(in directory: URL) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        var pending = [(directory, 0)]
        var count = 0
        while let (item, depth) = pending.popLast() {
            try Task.checkCancellation()
            count += 1
            guard depth <= 64, count <= 100_000 else {
                throw UpdateInstaller.Failure(message: "The update contains too many nested files.")
            }
            var info = stat()
            guard lstat(item.path, &info) == 0 else { throw UpdateInstaller.Failure(message: "Couldn't inspect the downloaded update.") }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                pending += try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil).map { ($0, depth + 1) }
            case mode_t(S_IFREG):
                guard info.st_nlink == 1 else { throw UpdateInstaller.Failure(message: "The update contains an unsafe hard link.") }
            case mode_t(S_IFLNK):
                let target = try fm.destinationOfSymbolicLink(atPath: item.path)
                let resolved = item.deletingLastPathComponent().appending(path: target).standardizedFileURL.resolvingSymlinksInPath()
                guard !target.hasPrefix("/"), resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
                    throw UpdateInstaller.Failure(message: "The update contains a symbolic link outside the app.")
                }
            default:
                throw UpdateInstaller.Failure(message: "The update contains an unsupported file type.")
            }
        }
    }
}
