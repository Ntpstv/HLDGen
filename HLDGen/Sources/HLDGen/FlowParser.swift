import Foundation

/// One `case .X, .Y:` branch inside a Flow's `vc.onRouteNext.bind { switch model.caseOutput { ... } }`,
/// with a best-effort human-readable destination resolved from its body.
struct FlowCaseDestination {
    var caseNames: [String]
    var destinationHint: String
}

/// One `func create<Scene>() -> FlowPage<VCClass>` block found in a Flow/*.swift coordinator,
/// with its Output-enum switch resolved to per-case destinations.
struct FlowScreenBinding {
    var vcClass: String
    var createFunc: String
    var cases: [FlowCaseDestination]
}

/// Flow coordinators (Flow/*Flow.swift) are extremely regular: each screen gets a
/// `func create<Name>() -> FlowPage<SomeViewController> { ... bindStyle: { vc in vc.onRouteNext.bind { switch
/// model.caseOutput { case .X: ...; self.showNext(type: NextVC.self) } } } }`. The VC itself never knows its own
/// destination — it only emits an Output enum case — so resolving "which screen does tapping this button reach"
/// requires parsing the sibling Flow file, not just the scene. This is the one cross-file join the tool does.
func parseFlowScreenBindings(_ flowSrc: String) -> [FlowScreenBinding] {
    var bindings: [FlowScreenBinding] = []

    for fn in extractFunctionBodies(flowSrc) {
        guard let sig = flowSrc.firstMatch(#"func\s+"# + NSRegularExpression.escapedPattern(for: fn.name) + #"\s*\(\s*\)\s*->\s*FlowPage\s*<\s*(\w+)\s*>"#) else { continue }
        let vcClass = sig[1]

        var cases = extractSwitchCases(fn.body)
        // Not every scene's Output is a branching enum — plenty emit a bare `PublishSubject<Void>` (only one
        // possible destination, so there's no case to switch on). Fall back to treating the whole
        // `vc.onRouteNext.bind { ... }` body as a single anonymous "_void" destination in that case.
        if cases.isEmpty, let bindRange = fn.body.range(of: ".bind") {
            let afterBind = String(fn.body[bindRange.upperBound...])
            let hint = destinationHint(from: afterBind)
            if !hint.isEmpty { cases = [FlowCaseDestination(caseNames: ["_void"], destinationHint: hint)] }
        }
        guard !cases.isEmpty else { continue }
        bindings.append(FlowScreenBinding(vcClass: vcClass, createFunc: fn.name, cases: cases))
    }
    return bindings
}

/// Splits a function body on `case .A, .B:` boundaries and derives a destination hint for each segment.
private func extractSwitchCases(_ body: String) -> [FlowCaseDestination] {
    let pattern = #"case\s+((?:\.\w+\s*,?\s*)+):"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = body as NSString
    let matches = re.matches(in: body, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return [] }

    var results: [FlowCaseDestination] = []
    for (idx, m) in matches.enumerated() {
        let namesRaw = ns.substring(with: m.range(at: 1))
        let names = namesRaw.matches(#"\.(\w+)"#).map { $0[1] }
        let segStart = m.range.location + m.range.length
        let segEnd = idx + 1 < matches.count ? matches[idx + 1].range.location : ns.length
        guard segEnd > segStart else { continue }
        let segment = ns.substring(with: NSRange(location: segStart, length: segEnd - segStart))
        results.append(FlowCaseDestination(caseNames: names, destinationHint: destinationHint(from: segment)))
    }
    return results
}

private func destinationHint(from segment: String) -> String {
    if let m = segment.firstMatch(#"showNext\(\s*type:\s*(\w+)\.self\s*\)"#) { return "\(m[1]) screen" }
    if let m = segment.firstMatch(#"self\.(\w+)\(\)\s*\.\s*bindStyle|self\.(create\w+)\(\)"#) {
        let name = m[1].isEmpty ? m[2] : m[1]
        if !name.isEmpty { return "\(name) screen" }
    }
    if segment.contains("completeFlow()") { return "flow completes (returns to caller / exits module)" }
    if segment.contains("closeFlow()") { return "closes flow" }
    if segment.contains("setNavToRootVc()") { return "pops to root — exits module" }
    if let m = segment.firstMatch(#"router\??\.routeTo(\w+)\s*\("#) { return "\(m[1]) (via router)" }
    if segment.contains("showNext()") { return "next queued screen in this flow" }
    // Fallback: first non-blank line, trimmed and capped, so there's always *something* concrete rather than "unknown".
    let firstLine = segment.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
}

/// Enum-case shorthand tokens (`.CaseName`) found in an action body — this is how a VC signals *which* Output
/// case it's emitting without necessarily naming it in an easily-regexed literal spot (e.g. a ternary picking
/// between two cases). Filtered against common non-enum dot-members so it doesn't pick up `.self`/`.main`/etc.
private let dotTokenStoplist: Set<String> = [
    "Self", "Main", "Shared", "None", "Default", "Init", "Class", "Type",
]
func extractEmittedCaseTokens(_ body: String) -> [String] {
    // `(?<!\w)\.` (no word char before the dot) tells apart bare enum-case shorthand (`.Back`, ` .Back`, `?.Back`)
    // from a namespaced type/member reference like `Home.CaseOutput` where the dot follows an identifier.
    // `(?!\()` excludes constructor calls like `.Output(caseOutput: ...)`, which is a type init, not a case.
    var tokens = body.matches(#"(?<!\w)\.([A-Z]\w*)\b(?!\()"#).map { $0[1] }
    // Some Output subjects are a bare `PublishSubject<Void>` — no case to find at all, just `.onNext(())`.
    // Tag that as the same "_void" sentinel parseFlowScreenBindings falls back to on the Flow side.
    if tokens.isEmpty, body.firstMatch(#"\.onNext\s*\(\s*\(\)\s*\)"#) != nil || body.firstMatch(#"\.onNext\s*\(\s*\)"#) != nil {
        tokens.append("_void")
    }
    var seen = Set<String>()
    return tokens.filter { !dotTokenStoplist.contains($0) && seen.insert($0).inserted }
}
