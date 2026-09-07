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
