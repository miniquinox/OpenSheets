import Darwin
import Foundation
import SheetModel

/// Turns a path a caller supplied into the one the kernel would actually open.
///
/// This is the first half of the workspace boundary (PLAN.md §7.2), and it is the half where
/// getting it *nearly* right is worthless. `URL.standardized` resolves `..` lexically, which
/// is wrong the moment a symlink is involved: `work/link/../../etc` standardises to `work/etc`
/// but opens `/etc` if `link` points at `/usr/share`. `URL.resolvingSymlinksInPath()` resolves
/// symlinks but only for components that exist, and does not re-resolve what `..` exposes.
///
/// So this walks the path the way `realpath(3)` does — one component at a time, resolving each
/// symlink as it is reached, and applying `..` to the **already-resolved** prefix. That
/// ordering is the whole game:
///
/// ```
/// /Users/q/work/escape/../secret      escape -> /Users/q/other
///   lexical:  /Users/q/work/secret    ← inside the grant. Wrong.
///   this:     /Users/q/secret         ← outside it. Correct.
/// ```
///
/// Non-existent trailing components are kept verbatim, because a path being checked before a
/// file is created is the normal case for a save. They cannot be symlinks — they do not exist —
/// so there is nothing left to resolve.
enum PathCanonicalizer {
    /// Cap on symlink hops, mirroring `MAXSYMLINKS`. A symlink loop must terminate as a
    /// refusal, not as a hang inside a security check.
    static let maximumSymlinkHops = 40

    /// The canonical absolute path, or an error when it cannot be determined.
    ///
    /// - Parameter workingDirectory: what a relative path is resolved against. Defaults to the
    ///   process's. A relative path reaching a security check is already suspicious, but
    ///   resolving it deterministically and then applying the full check is safer than
    ///   guessing at intent.
    static func canonicalize(
        _ path: String,
        workingDirectory: String? = nil
    ) throws(SheetError) -> String {
        var input = path
        guard !input.isEmpty else { throw SheetError.invalidArgument(name: "path", reason: "it is empty") }
        // Percent-encoding and `file://` are how a URL arrives from a tool call; neither is a
        // filesystem path, and treating one as a path is how `%2e%2e` becomes `..` one layer
        // too late.
        if input.hasPrefix("file://"), let url = URL(string: input), url.isFileURL {
            input = url.path(percentEncoded: false)
        }
        if input.hasPrefix("~") { input = (input as NSString).expandingTildeInPath }
        if !input.hasPrefix("/") {
            let base = workingDirectory ?? FileManager.default.currentDirectoryPath
            input = base.hasSuffix("/") ? base + input : base + "/" + input
        }

        var resolved: [String] = []
        var pending = input.split(separator: "/", omittingEmptySubsequences: true).map(String.init).reversed()
            .map { $0 }
        var hops = 0

        while let component = pending.popLast() {
            switch component {
            case ".":
                continue
            case "..":
                // Applied to the resolved prefix, which is what makes the example above work.
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            default:
                break
            }

            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            var status = stat()
            guard lstat(candidate, &status) == 0, (status.st_mode & S_IFMT) == S_IFLNK else {
                resolved.append(component)
                continue
            }

            hops += 1
            guard hops <= maximumSymlinkHops else {
                throw SheetError.workspaceGrantUnresolvable(path: path)
            }
            guard let target = readLink(candidate) else {
                throw SheetError.workspaceGrantUnresolvable(path: path)
            }
            let targetComponents = target
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            if target.hasPrefix("/") { resolved.removeAll() }
            pending.append(contentsOf: targetComponents.reversed())
        }

        // NFC everywhere. APFS stores what it is given, so the same directory can be spelled
        // in NFC by one producer and NFD by another; comparing the two forms byte for byte
        // would report them as different directories and deny a legitimate path.
        return "/" + resolved.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    /// See ``canonicalize(_:workingDirectory:)``.
    static func canonicalize(_ url: URL, workingDirectory: String? = nil) throws(SheetError) -> String {
        try canonicalize(url.path(percentEncoded: false), workingDirectory: workingDirectory)
    }

    /// The canonical path split into components, which is the only form the containment check
    /// is allowed to compare. String prefixes make `/Users/q/work-secret` a child of
    /// `/Users/q/work`; component lists do not.
    static func components(_ canonicalPath: String) -> [String] {
        canonicalPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Whether `path` is `container` or lives underneath it.
    ///
    /// - Parameter caseInsensitive: pass what the *container's volume* reports for
    ///   ``URLResourceKey/volumeSupportsCaseSensitiveNamesKey``. On a case-insensitive volume
    ///   `Work` and `work` are the same directory and must match; on a case-sensitive one they
    ///   are two directories and must not.
    static func contains(container: [String], path: [String], caseInsensitive: Bool) -> Bool {
        guard path.count >= container.count else { return false }
        for (index, component) in container.enumerated() {
            let candidate = path[index]
            if caseInsensitive {
                guard component.compare(candidate, options: [.caseInsensitive]) == .orderedSame else { return false }
            } else {
                guard component == candidate else { return false }
            }
        }
        return true
    }

    /// Whether the volume holding `path` treats `A` and `a` as different names.
    ///
    /// Measured rather than assumed: the boot volume is normally case-insensitive, but
    /// developer volumes frequently are not, and the answer decides whether comparing case
    /// insensitively widens a grant or merely accepts a differently-typed path.
    static func volumeIsCaseSensitive(_ path: String) -> Bool {
        var probe = URL(fileURLWithPath: path)
        for _ in 0 ..< 64 {
            if let values = try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
               let sensitive = values.volumeSupportsCaseSensitiveNames {
                return sensitive
            }
            let parent = probe.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == probe.path(percentEncoded: false) { break }
            probe = parent
        }
        // Unknown volume: assume case-sensitive, which is the answer that never widens a grant.
        return true
    }

    private static func readLink(_ path: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return base.withMemoryRebound(to: CChar.self, capacity: pointer.count) { chars in
                readlink(path, chars, pointer.count - 1)
            }
        }
        guard length > 0 else { return nil }
        // `readlink` does not terminate the buffer, so the length is the only thing that says
        // where the target ends.
        return String(decoding: buffer[0 ..< length], as: UTF8.self)
    }
}
