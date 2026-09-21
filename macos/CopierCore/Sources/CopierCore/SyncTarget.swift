import Foundation

/// Folder Sync target resolution.
public enum SyncTarget {
    /// Resolve the effective sync target.
    /// - `append`: sync into `<targetPath>/<source basename>`.
    /// - otherwise: use `targetPath` as-is.
    ///
    /// An empty target stays empty; an empty source disables appending.
    public static func resolve(sourcePath: String, targetPath: String, appendSourceName: Bool) -> String {
        guard !targetPath.isEmpty else { return "" }
        guard appendSourceName, !sourcePath.isEmpty else { return targetPath }
        return "\(trimTrailingSlashes(targetPath))/\(basename(sourcePath))"
    }

    /// URL-taking convenience for the app layer.
    public static func resolve(source: URL, target: URL, appendSourceName: Bool) -> URL {
        URL(fileURLWithPath: resolve(sourcePath: source.path, targetPath: target.path, appendSourceName: appendSourceName))
    }

    static func basename(_ path: String) -> String {
        trimTrailingSlashes(path).split(separator: "/").last.map(String.init) ?? ""
    }

    static func trimTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
