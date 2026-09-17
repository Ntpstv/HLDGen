import Foundation

/// Screen-level facts an HLD reader asks about that are not navigation or HTTP:
/// what the navigation bar says, which notifications the screen posts or listens for, and what it
/// reads from or writes to local storage. Read from the scene's own files, so it works the same
/// whatever the architecture.
struct ScreenFacts {
    var titleKey = ""
    var navBarHidden = false
    var notifications: [String] = []
    var localStorage: [String] = []
}

func extractScreenFacts(sceneDir: URL) -> ScreenFacts {
    var facts = ScreenFacts()
    var notes: [String] = []
    var storage: [String] = []

    for file in findSceneFiles(under: sceneDir, extensions: ["swift"]) {
        let src = readFile(file)

        if facts.titleKey.isEmpty, file.lastPathComponent.hasSuffix("ViewController.swift") {
            facts.titleKey = navigationTitle(in: src) ?? ""
            if src.contains("isShowNavBar = false") || src.contains("setNavigationBarHidden(true") {
                facts.navBarHidden = true
            }
        }

        for m in src.matches(#"NotificationCenter\.default\.post\(\s*name:\s*([^,)]+)"#) {
            notes.append("post · \(notificationName(m[1]))")
        }
        for m in src.matches(#"addObserver\((?:[^()]|\([^()]*\))*?name:\s*([^,)]+)"#,
                             options: [.dotMatchesLineSeparators]) {
            notes.append("observe · \(notificationName(m[1]))")
        }
        for m in src.matches(#"rx\.notification\(\s*([^,)]+)"#) {
            notes.append("observe · \(notificationName(m[1]))")
        }

        // Wrapper services are how this codebase touches storage; raw UserDefaults is the fallback.
        for m in src.matches(#"\b(\w*(?:UserDefault|KeyChain|Keychain)\w*Service|\w*Keychain\w*|\w*KeyChain\w*)\.(\w+)"#) {
            storage.append("\(m[1]).\(m[2])")
        }
        for m in src.matches(#"UserDefaults\.standard\.(\w+)\((?:[^()]|\([^()]*\))*?forKey:\s*\"([^\"]+)\""#) {
            storage.append("UserDefaults.\(m[1]) \"\(m[2])\"")
        }
    }

    facts.notifications = orderedUnique(notes)
    facts.localStorage = orderedUnique(storage)
    return facts
}

/// The title a view controller gives its navigation bar, as a localisation key or a literal.
///
/// Titles are passed to a navigation-setup helper (`setPTPBackgroundAndTheme(title:)`,
/// `setupNavigationWhiteBar(title:)`, …) far more often than assigned to `title` directly. Only a
/// `title:` argument inside such a call counts — the same label on an alert is not the screen title.
private func navigationTitle(in src: String) -> String? {
    // Setup-style helpers only, and only the `title:` inside that call's own parentheses. A loose
    // 400-character window ran past the call into an error popup and reported its heading instead.
    let helper = #"\b(?:setPTPBackgroundAndTheme|setup\w*Nav\w*|set\w*Nav\w*Bar\w*|configure\w*Nav\w*)\s*\("#
    for (_, start) in src.matchesWithRange(helper) {
        guard let open = src.range(of: "(", range: start..<src.endIndex),
              let args = parenthesised(from: open.lowerBound, in: src) else { continue }
        if let m = args.firstMatch(#"(?:^|[,(\s])title:\s*\"([^\"]+)\""#) { return m[1] }
    }
    // Explicit receivers only: a bare `title = "…"` is as often a local variable holding an error
    // heading as it is the view controller's own title.
    if let m = src.firstMatch(#"(?:navigationItem\.title|self\.title)\s*=\s*\"([^\"]+)\""#) {
        return m[1]
    }
    return nil
}

/// Text inside the parenthesis at `open` and its match.
private func parenthesised(from open: String.Index, in src: String) -> String? {
    var depth = 0
    var i = open
    while i < src.endIndex {
        if src[i] == "(" { depth += 1 }
        else if src[i] == ")" {
            depth -= 1
            if depth == 0 { return String(src[src.index(after: open)..<i]) }
        }
        i = src.index(after: i)
    }
    return nil
}

/// `NSNotification.Name(rawValue: "x")` → `x`, `UIResponder.keyboardWillShowNotification` → `keyboardWillShow`.
private func notificationName(_ raw: String) -> String {
    var n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let m = n.firstMatch(#"rawValue:\s*\"([^\"]+)\""#) { return m[1] }
    if let m = n.firstMatch(#"\"([^\"]+)\""#) { return m[1] }
    n = n.split(separator: ".").last.map(String.init) ?? n
    if n.hasSuffix("Notification") { n.removeLast("Notification".count) }
    return n
}

private func orderedUnique(_ items: [String]) -> [String] {
    var seen = Set<String>()
    return items.filter { seen.insert($0).inserted }
}

/// Localisation table for resolving title keys to the text a user sees. Thai is the app's primary
/// language, so `th.lproj` wins; strings from the analysed module win over same-named keys elsewhere.
func loadLocalizations(under root: URL, module: String) -> [String: String] {
    var moduleTH: [String: String] = [:], moduleOther: [String: String] = [:]
    var globalTH: [String: String] = [:], globalOther: [String: String] = [:]

    for file in findFiles(under: root, extensions: ["strings"]) {
        let path = file.path
        guard !path.contains("/.build/") else { continue }
        let isTH = path.contains("/th.lproj/")
        let isModule = path.contains("/\(module)/")
        for m in readFile(file).matches(#"\"((?:[^\"\\]|\\.)+)\"\s*=\s*\"((?:[^\"\\]|\\.)*)\"\s*;"#) {
            switch (isModule, isTH) {
            case (true, true):   if moduleTH[m[1]] == nil { moduleTH[m[1]] = m[2] }
            case (true, false):  if moduleOther[m[1]] == nil { moduleOther[m[1]] = m[2] }
            case (false, true):  if globalTH[m[1]] == nil { globalTH[m[1]] = m[2] }
            case (false, false): if globalOther[m[1]] == nil { globalOther[m[1]] = m[2] }
            }
        }
    }
    return globalOther
        .merging(globalTH) { _, new in new }
        .merging(moduleOther) { _, new in new }
        .merging(moduleTH) { _, new in new }
}
