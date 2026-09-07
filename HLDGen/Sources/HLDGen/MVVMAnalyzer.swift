import Foundation

/// Analyzes an MVVM scene directory (*ViewController + *ViewModel, no Interactor).
/// Extracts ViewModel inputs/outputs, Combine/@Published bindings, and API calls.
func analyzeMVVM(module: String, sceneName: String, sceneDir: URL,
                 serviceEndpoints: [String: ApiEndpoint]) -> SceneResult {
    let files = findFiles(under: sceneDir, extensions: ["swift"])
    var viewControllers: [String] = []
    var viewModels: [String] = []
    var actionChains: [ActionChain] = []
    var servicesUsed: Set<String> = []

    var vmFunctions: [String: String] = [:]

    // Pass 1: collect ViewModel functions
    for file in files {
        let name = file.lastPathComponent
        let src  = readFile(file)
        if name.contains("ViewModel") || name.contains("VM") {
            for m in src.matches(#"class\s+(\w+(?:ViewModel|VM))\b"#) { viewModels.append(m[1]) }
            for fn in extractFunctionBodies(src) { vmFunctions[fn.name] = fn.body }
            // @Published properties as "outputs"
            for m in src.matches(#"@Published\s+var\s+(\w+)"#) {
                servicesUsed.insert("@Published:\(m[1])")
            }
        }
        if name.contains("ViewController") || name.contains("VC") {
            for m in src.matches(#"class\s+(\w+(?:ViewController|VC))\b"#) { viewControllers.append(m[1]) }
        }
    }

    // Pass 2: VC actions that call into the ViewModel
    for file in files {
        let name = file.lastPathComponent
        guard name.contains("ViewController") || name.contains("VC") else { continue }
        let src = readFile(file)
        let rel = file.path

        for fn in extractFunctionBodies(src) {
            let body = fn.body

            // Find viewModel.someMethod() calls
            var vmCalls: [String] = []
            for m in body.matches(#"(?:viewModel|vm|self\.viewModel)\.\(?(\w+)\s*\("#) { vmCalls.append(m[1]) }

            // Navigation
            var vcRoutes: [String] = []
            for m in body.matches(#"performSegue\(withIdentifier:\s*"([^"]+)""#) { vcRoutes.append("segue:\(m[1])") }
            for m in body.matches(#"present\((\w+)"#)   { vcRoutes.append("present:\(m[1])") }
            for m in body.matches(#"push\w*\((\w+)"#)   { vcRoutes.append("push:\(m[1])") }

            guard !vmCalls.isEmpty || !vcRoutes.isEmpty else { continue }

            // Resolve ViewModel calls to API calls
            var calls: [ResolvedInteractorCall] = []
            for vmMethod in vmCalls {
                guard let vmBody = vmFunctions[vmMethod] else {
                    calls.append(ResolvedInteractorCall(interactorMethod: vmMethod, services: [], workers: [], routes: []))
                    continue
                }
                var apiCalls: [String] = []
                for m in vmBody.matches(#"(\w+(?:Service|Manager|Client|API|Repository))\.\w+\("#) {
                    apiCalls.append("\(m[1])")
                    servicesUsed.insert(m[1])
                }
                // Async/await API pattern
                for m in vmBody.matches(#"await\s+(\w+)\.\w+\("#) { apiCalls.append("async:\(m[1])") }
                calls.append(ResolvedInteractorCall(interactorMethod: vmMethod, services: apiCalls, workers: [], routes: []))
            }

            actionChains.append(ActionChain(
                action: fn.name, kind: fn.kind, file: rel,
                calls: calls, vcRoutes: vcRoutes,
                emittedCases: [], resolvedDestinations: []
            ))
        }
    }

    // Also scan ViewModel directly for observable trigger points (Combine sink / Rx subscribe)
    for file in files {
        let name = file.lastPathComponent
        guard name.contains("ViewModel") || name.contains("VM") else { continue }
        let src = readFile(file)
        let rel = file.path

        // Combine: somePublisher.sink { ... }
        let ns = src as NSString
        if let re = try? NSRegularExpression(pattern: #"(\w+)\.sink\s*\{"#) {
            for m in re.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                let publisher = ns.substring(with: m.range(at: 1))
                let start = m.range.location
                let end = min(start + 3000, ns.length)
                let body = ns.substring(with: NSRange(location: start, length: end - start))
                var apiCalls: [String] = []
                for match in body.matches(#"(\w+(?:Service|Manager|Client|API|Repository))\.\w+\("#) {
                    apiCalls.append(match[1]); servicesUsed.insert(match[1])
                }
                if !apiCalls.isEmpty {
                    actionChains.append(ActionChain(
                        action: "\(publisher).sink", kind: "rxBinding", file: rel,
                        calls: [ResolvedInteractorCall(interactorMethod: "\(publisher).sink", services: apiCalls, workers: [], routes: [])],
                        vcRoutes: [], emittedCases: [], resolvedDestinations: []
                    ))
                }
            }
        }
    }

    let resolvedEndpoints = servicesUsed.compactMap { serviceEndpoints[$0] }

    return SceneResult(
        id: "\(module)/\(sceneName)", name: sceneName, module: module,
        viewControllers: viewControllers, interactors: viewModels, presenters: [],
        routers: [], workers: [], routesTo: [],
        servicesUsed: servicesUsed.sorted(),
        actionChains: actionChains,
        xibs: parseSceneStoryboards(in: sceneDir),
        apiEndpoints: resolvedEndpoints
    )
}
