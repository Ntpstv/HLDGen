import Foundation

/// Analyzes a SwiftUI scene directory (struct * : View, no ViewController).
/// Extracts NavigationLink destinations, .sheet/.fullScreenCover presentations,
/// @StateObject/@ObservedObject ViewModel calls, and async API calls.
func analyzeSwiftUI(module: String, sceneName: String, sceneDir: URL,
                    serviceEndpoints: [String: ApiEndpoint]) -> SceneResult {
    let files = findSceneFiles(under: sceneDir, extensions: ["swift"])
    var viewNames: [String] = []
    var actionChains: [ActionChain] = []
    var servicesUsed: Set<String> = []
    var routesTo: Set<String> = []

    for file in files {
        let src  = readFile(file)
        let rel  = file.path

        // Collect View struct names
        for m in src.matches(#"struct\s+(\w+)\s*:\s*View\b"#) { viewNames.append(m[1]) }

        // ── Navigation destinations ──────────────────────────────────────────
        var vcRoutes: [String] = []
        // NavigationLink(destination: SomeView())
        for m in src.matches(#"NavigationLink\s*\(\s*(?:destination:\s*)?(\w+)\s*[{\(]"#) {
            let dest = m[1]
            vcRoutes.append("NavigationLink→\(dest)")
            routesTo.insert(dest)
        }
        // .navigationDestination(for: X.self) { _ in SomeView() }
        for m in src.matches(#"navigationDestination.*\{\s*_?\s*in\s+(\w+)\s*[{\(]"#) {
            vcRoutes.append("navDestination→\(m[1])")
            routesTo.insert(m[1])
        }
        // .sheet(isPresented:) { SomeView() }  /  .fullScreenCover
        for m in src.matches(#"\.(?:sheet|fullScreenCover)\(.*?\)\s*\{[^}]*?(\w+View)\s*[{\(]"#) {
            vcRoutes.append("sheet→\(m[1])")
            routesTo.insert(m[1])
        }

        if !vcRoutes.isEmpty {
            actionChains.append(ActionChain(
                action: "navigation", kind: "func", file: rel,
                calls: [], vcRoutes: vcRoutes, emittedCases: [], resolvedDestinations: []
            ))
        }

        // ── Action / button handlers ─────────────────────────────────────────
        for fn in extractFunctionBodies(src) {
            let body = fn.body
            var calls: [ResolvedInteractorCall] = []
            var apiList: [String] = []

            // async/await API calls
            for m in body.matches(#"await\s+(\w+)\.(\w+)\s*\("#) {
                let call = "\(m[1]).\(m[2])"
                apiList.append(call)
                servicesUsed.insert(m[1])
            }
            // Direct service/repo calls
            for m in body.matches(#"(\w+(?:Service|Repository|Client|API|Manager))\.\w+\s*\("#) {
                apiList.append(m[1]); servicesUsed.insert(m[1])
            }
            // Task { } blocks containing API calls
            for m in body.matches(#"Task\s*\{([^}]+)\}"#) {
                for am in m[1].matches(#"await\s+(\w+)\.(\w+)\s*\("#) {
                    apiList.append("\(am[1]).\(am[2])"); servicesUsed.insert(am[1])
                }
            }

            var navRoutes: [String] = []
            for m in body.matches(#"NavigationLink.*?(\w+View)\s*[{\(]"#) { navRoutes.append("NavigationLink→\(m[1])") }

            guard !apiList.isEmpty || !navRoutes.isEmpty else { continue }

            if !apiList.isEmpty {
                calls.append(ResolvedInteractorCall(interactorMethod: fn.name, services: apiList, workers: [], routes: navRoutes))
            }
            actionChains.append(ActionChain(
                action: fn.name, kind: fn.kind, file: rel,
                calls: calls, vcRoutes: navRoutes, emittedCases: [], resolvedDestinations: []
            ))
        }

        // ── @StateObject / @ObservedObject ───────────────────────────────────
        // Treat these as "services" for the API cloud
        for m in src.matches(#"@(?:StateObject|ObservedObject)\s+var\s+\w+\s*[:=]\s*(\w+)\s*[(\{]"#) {
            servicesUsed.insert(m[1])
        }
    }

    let resolvedEndpoints = servicesUsed.compactMap { serviceEndpoints[$0] }

    return SceneResult(
        id: "\(module)/\(sceneName)", name: sceneName, module: module,
        viewControllers: viewNames, interactors: [], presenters: [],
        routers: [], workers: [], routesTo: routesTo.sorted(),
        servicesUsed: servicesUsed.sorted(),
        actionChains: actionChains,
        xibs: [],   // SwiftUI has no .xib / .storyboard
        apiEndpoints: resolvedEndpoints
    )
}
