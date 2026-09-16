import Foundation

/// Parses an API-router file (e.g. MyModule/API/MyRouter.swift):
///
///   static func caseName(_ parameters: Parameters) -> ApiModel {
///       return SomeApiModel(path: "/api/v1/...", method: .post, parameters)
///   }
///
/// Returns one ApiEndpoint per `static func`, keyed by the function name so a Service file's
/// `MyRouter.caseName(...)` call site can be resolved to a concrete path + HTTP method.
func parseApiRouterFile(_ url: URL) -> [ApiEndpoint] {
    let src = readFile(url)
    let pattern = #"static\s+func\s+(\w+)\s*\([^)]*\)\s*->\s*\w+\s*\{\s*return\s+\w+\(\s*path:\s*"([^"]+)"\s*,\s*method:\s*\.(\w+)"#
    let byFunc = src.matches(pattern, options: [.dotMatchesLineSeparators]).map {
        ApiEndpoint(caseName: $0[1], path: $0[2], method: $0[3].uppercased())
    }
    return byFunc.isEmpty ? parseEnumRouter(src) : byFunc
}

/// The other common router shape: an enum of endpoints whose paths live in a `switch` inside a
/// computed property, rather than one `static func` per endpoint.
///
///     enum MyRouter {
///         case couponList(parameters: Parameters)
///         var method: HTTPMethod { return .post }          // or a switch, like `path`
///         var path: String {
///             switch self {
///             case .couponList: return "/v1/misc/banners/list"
///             }
///         }
///     }
///
/// Without this, a module using the enum shape resolves zero endpoints and every API cloud on the
/// board falls back to bare service-class names.
private func parseEnumRouter(_ rawSrc: String) -> [ApiEndpoint] {
    // Routers accumulate commented-out drafts of the very properties being parsed. Left in, the
    // brace matcher locks onto a dead `// var path: String {` block and returns its stale arms.
    let src = strippingComments(rawSrc)
    guard let pathBlock = switchBody(of: "path", in: src) else { return [] }

    // A `method` switch maps each case to its own verb; a lone `return .post` covers every case.
    var methodByCase: [String: String] = [:]
    var defaultMethod = "POST"
    if let methodBlock = switchBody(of: "method", in: src) {
        for m in methodBlock.matches(#"case\s+([^:]+):[^"]*?return\s+\.(\w+)"#, options: [.dotMatchesLineSeparators]) {
            let verb = m[2].uppercased()
            // One `case .a, .b:` arm can cover several endpoints.
            for name in m[1].split(separator: ",") {
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: ".", with: "")
                if let id = clean.split(separator: "(").first { methodByCase[String(id)] = verb }
            }
        }
    } else if let m = src.firstMatch(#"var\s+method\s*:\s*\w+\s*\{\s*return\s+\.(\w+)"#) {
        defaultMethod = m[1].uppercased()
    }

    var endpoints: [ApiEndpoint] = []
    for m in pathBlock.matches(#"case\s+([^:]+):\s*(?:\/\/[^\n]*\n\s*)*return\s+"([^"]+)""#,
                               options: [.dotMatchesLineSeparators]) {
        let path = m[2]
        for name in m[1].split(separator: ",") {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ".", with: "")
            guard let id = clean.split(separator: "(").first, !id.isEmpty else { continue }
            let caseName = String(id)
            endpoints.append(ApiEndpoint(caseName: caseName,
                                         path: path,
                                         method: methodByCase[caseName] ?? defaultMethod))
        }
    }
    return endpoints
}

/// Body of the `switch self { … }` inside `var <name>`, found by brace matching because the arms
/// themselves contain braces (string interpolation, nested calls) that a regex would trip over.
///
/// A file can declare the same property name several times — a protocol requirement
/// (`var path: String { get }`), a commented-out draft, then the real implementation — so every
/// candidate is checked and the first one whose own body actually holds a `switch self` wins.
/// Taking the first textual match instead made a router parse its `method` switch as its `path`
/// switch and resolve nothing.
private func switchBody(of property: String, in src: String) -> String? {
    var searchFrom = src.startIndex
    while let decl = src.range(of: #"var\s+"# + property + #"\s*:"#,
                               options: .regularExpression,
                               range: searchFrom..<src.endIndex) {
        searchFrom = decl.upperBound
        guard let open = src.range(of: "{", range: decl.upperBound..<src.endIndex),
              let body = bracedBody(from: open.lowerBound, in: src) else { continue }
        guard body.contains("switch self"),
              let sw = body.range(of: "switch self"),
              let swOpen = body.range(of: "{", range: sw.upperBound..<body.endIndex),
              let swBody = bracedBody(from: swOpen.lowerBound, in: body) else { continue }
        return swBody
    }
    return nil
}

/// Removes `//` and `/* */` comments, leaving string literals intact — a path such as
/// `"https://host/v1"` must survive, and a naive strip would cut it at the `//`.
private func strippingComments(_ src: String) -> String {
    var out = ""
    out.reserveCapacity(src.count)

    var inString = false, inLine = false, inBlock = false, escaped = false
    var i = src.startIndex
    while i < src.endIndex {
        let c = src[i]
        let next = src.index(after: i) < src.endIndex ? src[src.index(after: i)] : nil

        if inLine {
            if c == "\n" { inLine = false; out.append(c) }
        } else if inBlock {
            if c == "*" && next == "/" { inBlock = false; i = src.index(after: i) }
        } else if inString {
            out.append(c)
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { inString = false }
        } else if c == "\"" {
            inString = true; out.append(c)
        } else if c == "/" && next == "/" {
            inLine = true; i = src.index(after: i)
        } else if c == "/" && next == "*" {
            inBlock = true; i = src.index(after: i)
        } else {
            out.append(c)
        }
        i = src.index(after: i)
    }
    return out
}

/// Contents between the brace at `open` and its match.
private func bracedBody(from open: String.Index, in src: String) -> String? {
    var depth = 0
    var i = open
    while i < src.endIndex {
        if src[i] == "{" { depth += 1 }
        else if src[i] == "}" {
            depth -= 1
            if depth == 0 { return String(src[src.index(after: open)..<i]) }
        }
        i = src.index(after: i)
    }
    return nil
}

/// For a Service.swift file (a `BaseApi<Req, Resp>` / `BaseService<...>` subclass), find which
/// `<SomeRouter>.<caseName>(` it calls in `createUrlReq`, so we can attach the resolved endpoint later.
/// Returns (routerTypeName, caseName), e.g. ("MyRouter", "menuWhiteList").
func findRouterCall(in serviceSrc: String) -> (router: String, caseName: String)? {
    // `\w*`, not `\w+`: one framework's router is named plainly `Router`, and requiring a prefix
    // silently skipped every call site in it.
    guard let m = serviceSrc.firstMatch(#"\b(\w*Router)\.(\w+)\s*\("#) else { return nil }
    return (m[1], m[2])
}
