import Foundation

struct SwiftFunction {
    var name: String
    var kind: String // "ibaction" | "objc" | "func"
    var body: String
}

/// Ports analyze_ios.py's extract_function_bodies: for every `func name(...)` in `src`, look back up to
/// two lines for an `@IBAction`/`@objc` attribute, then extract the body by counting braces.
/// Brace-counting (rather than a real parser) is intentional here — it's what the codebase-wide Python
/// prototype already validated on this exact monorepo, and a full SwiftSyntax AST is out of scope for v1.
func extractFunctionBodies(_ src: String) -> [SwiftFunction] {
    let lines = src.components(separatedBy: "\n")
    var funcs: [SwiftFunction] = []
    var i = 0
    while i < lines.count {
        let line = lines[i]
        if let m = line.firstMatch(#"func\s+(\w+)\s*\("#) {
            let prevStart = max(0, i - 2)
            let prev = lines[prevStart...i].joined(separator: "\n")
            let kind: String
            if prev.contains("@IBAction") { kind = "ibaction" }
            else if prev.contains("@objc") { kind = "objc" }
            else { kind = "func" }

            var bodyLines: [String] = []
            var depth = 0
            var started = false
            var j = i
            while j < lines.count {
                let l = lines[j]
                for ch in l {
                    if ch == "{" { depth += 1; started = true }
                    else if ch == "}" { depth -= 1 }
                }
                if started { bodyLines.append(l) }
                if started && depth == 0 { break }
                j += 1
            }
            funcs.append(SwiftFunction(name: m[1], kind: kind, body: bodyLines.joined(separator: "\n")))
        }
        i += 1
    }
    return funcs
}

/// interactor?.methodName() calls from a VC action body.
func extractInteractorCalls(_ body: String) -> [String] {
    body.matches(#"interactor\??\.(\w+)\s*\("#).map { $0[1] }
}

/// router?.routeToXxx() calls from a function body (VC action or interactor method).
func extractRouteCalls(_ body: String) -> [String] {
    body.matches(#"router\??\.routeTo(\w+)\s*\("#).map { $0[1] }
}

/// workerVar.methodName() calls from an interactor method body.
func extractWorkerCalls(_ body: String) -> [(varName: String, method: String)] {
    body.matches(#"(\w+[Ww]orker|[Ww]orker\w+)\.(\w+)\s*\("#).map { ($0[1], $0[2]) }
}

/// service.execute()/service.methodName() calls, resolving `let x = FooService()` locals to their class name
/// so the caller sees ("FooService", "execute") instead of the anonymous local variable name.
func extractServiceCalls(_ body: String) -> [(serviceOrVar: String, method: String)] {
    var localMap: [String: String] = [:]
    for m in body.matches(#"\blet\s+(\w+)\s*=\s*(\w+Service)\s*\("#) { localMap[m[1]] = m[2] }
    for m in body.matches(#"\bvar\s+(\w+)\s*:\s*(\w+Service)\b"#) { localMap[m[1]] = m[2] }

    var results: [(String, String)] = []
    for m in body.matches(#"(\w+[Ss]ervice|[Ss]ervice\w+)\.(\w+)\s*\("#) {
        results.append((m[1], m[2]))
    }
    // Inline instantiate-then-call, e.g. `ValidatePublicQRService().execute(request:...)` — this
    // codebase's dominant idiom (a fresh instance per call site, no stored/local variable at all).
    for m in body.matches(#"(\w+Service)\s*\(\s*\)\s*\.(\w+)\s*\("#) {
        results.append((m[1], m[2]))
    }
    for (varName, className) in localMap {
        let escaped = NSRegularExpression.escapedPattern(for: varName)
        for m in body.matches("\\b\(escaped)\\.(\\w+)\\s*\\(") {
            results.append((className, m[1]))
        }
    }
    return results
}
