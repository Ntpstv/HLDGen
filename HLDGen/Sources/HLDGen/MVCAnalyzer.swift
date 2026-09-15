import Foundation

/// Analyzes a plain MVC scene directory (*ViewController.swift, no Interactor/Router).
/// Extracts IBActions, segues, direct API/URLSession calls, and navigation calls.
func analyzeMVC(module: String, sceneName: String, sceneDir: URL,
                serviceEndpoints: [String: ApiEndpoint]) -> SceneResult {
    let files = findSceneFiles(under: sceneDir, extensions: ["swift"])
    var viewControllers: [String] = []
    var actionChains: [ActionChain] = []
    var servicesUsed: Set<String> = []

    for file in files {
        let src  = readFile(file)
        let rel  = file.path
        let name = file.lastPathComponent

        // Collect VC class names
        for m in src.matches(#"class\s+(\w+(?:ViewController|VC))\b"#) {
            viewControllers.append(m[1])
        }

        guard name.contains("ViewController") || name.contains("VC") else { continue }

        for fn in extractFunctionBodies(src) {
            let body = fn.body

            // Navigation: performSegue / present / push
            var vcRoutes: [String] = []
            for m in body.matches(#"performSegue\(withIdentifier:\s*"([^"]+)""#) { vcRoutes.append("segue:\(m[1])") }
            for m in body.matches(#"present\((\w+)"#)                             { vcRoutes.append("present:\(m[1])") }
            for m in body.matches(#"pushViewController\((\w+)"#)                  { vcRoutes.append("push:\(m[1])") }
            for m in body.matches(#"show\((\w+)"#)                                { vcRoutes.append("show:\(m[1])") }

            // Direct API calls: URLSession, Alamofire, AF.request
            var calls: [ResolvedInteractorCall] = []
            var apiServices: [String] = []
            for _ in body.matches(#"URLSession\.shared\.\w+\(url"#) {
                apiServices.append("URLSession")
                calls.append(ResolvedInteractorCall(interactorMethod: fn.name, services: ["URLSession.dataTask"], workers: [], routes: []))
            }
            for m in body.matches(#"AF\.request\(([^,\)]+)"#) {
                let endpoint = m[1].trimmingCharacters(in: .whitespaces)
                apiServices.append("Alamofire")
                calls.append(ResolvedInteractorCall(interactorMethod: fn.name, services: ["AF.request(\(endpoint))"], workers: [], routes: []))
            }
            // Custom service classes (ending in Service/Manager/Client/API)
            for m in body.matches(#"(\w+(?:Service|Manager|Client|API))\.\w+\("#) {
                let svc = m[1]
                apiServices.append(svc)
                servicesUsed.insert(svc)
            }

            let isIBAction = fn.kind == "ibaction" || fn.kind == "objc"
            let hasNav     = !vcRoutes.isEmpty
            let hasApi     = !apiServices.isEmpty

            guard isIBAction || hasNav || hasApi else { continue }

            actionChains.append(ActionChain(
                action: fn.name, kind: fn.kind, file: rel,
                calls: calls, vcRoutes: vcRoutes,
                emittedCases: [], resolvedDestinations: []
            ))
        }
    }

    let resolvedEndpoints = servicesUsed.compactMap { serviceEndpoints[$0] }

    return SceneResult(
        id: "\(module)/\(sceneName)", name: sceneName, module: module,
        viewControllers: viewControllers, interactors: [], presenters: [],
        routers: [], workers: [], routesTo: [],
        servicesUsed: servicesUsed.sorted(),
        actionChains: actionChains,
        xibs: parseSceneStoryboards(in: sceneDir),
        apiEndpoints: resolvedEndpoints
    )
}
