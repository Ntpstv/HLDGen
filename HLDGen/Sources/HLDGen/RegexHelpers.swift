import Foundation

extension String {
    /// All non-overlapping matches of `pattern`, each returned as an array of capture-group strings
    /// (group 0 = full match, group 1.. = capture groups). Mirrors Python's re.findall with tuples.
    func matches(_ pattern: String, options: NSRegularExpression.Options = []) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = self as NSString
        let all = re.matches(in: self, range: NSRange(location: 0, length: ns.length))
        return all.map { match in
            (0..<match.numberOfRanges).map { i in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    /// Like `matches`, but also reports where each match starts — needed when the text after a
    /// match has to be brace-matched (a type declaration followed by its body).
    func matchesWithRange(_ pattern: String,
                          options: NSRegularExpression.Options = []) -> [(groups: [String], start: Index)] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            guard let start = Range(match.range, in: self)?.lowerBound else { return nil }
            return (groups, start)
        }
    }

    /// First match's capture groups (group 1..), or nil if no match.
    func firstMatch(_ pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = self as NSString
        guard let match = re.firstMatch(in: self, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            let r = match.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

func readFile(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

/// Recursively enumerate files under `dir` whose extension matches (case-insensitive).
func findFiles(under dir: URL, extensions: Set<String>) -> [URL] {
    guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    var result: [URL] = []
    for case let url as URL in en {
        if extensions.contains(url.pathExtension.lowercased()) {
            result.append(url)
        }
    }
    return result.sorted { $0.path < $1.path }
}

/// True if `dir` directly holds a `*ViewController.swift` — i.e. it is a scene in its own right.
func isSceneDir(_ dir: URL) -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.contains { $0.hasSuffix("ViewController.swift") }
}

/// Like `findFiles`, but stops at nested scenes. A folder such as `Scenes/Home` often holds its own
/// `PTPHomeViewController.swift` *and* a subfolder per sibling screen; walking it recursively would
/// collapse ten separate screens into one. Descent stops at any subdirectory that is itself a scene.
func findSceneFiles(under dir: URL, extensions: Set<String>) -> [URL] {
    guard let en = FileManager.default.enumerator(
        at: dir, includingPropertiesForKeys: [.isDirectoryKey]
    ) else { return [] }
    var result: [URL] = []
    for case let url as URL in en {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            if isSceneDir(url) { en.skipDescendants() }
            continue
        }
        if extensions.contains(url.pathExtension.lowercased()) {
            result.append(url)
        }
    }
    return result.sorted { $0.path < $1.path }
}
