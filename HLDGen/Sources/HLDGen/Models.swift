import Foundation

/// One positioned view in a wireframe, recursively parsed from a .storyboard/.xib <objects> tree.
/// x/y/w/h are the real Interface Builder frame values, so a renderer can lay this out to scale.
struct WireNode: Codable {
    var type: String
    var color: String
    var label: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var actions: [String]?
    var children: [WireNode]
}

/// The parsed contents of a single storyboard scene or xib file.
struct StoryboardResult: Codable {
    var source: String // "xib" | "storyboard"
    var vcClass: String?
    var file: String
    var width: Double
    var height: Double
    var nodes: [WireNode]
    var outlets: [String]
    var actions: [String]
}

/// A worker call resolved one level deep from an interactor method (workerVar.method -> services it calls).
struct ResolvedWorkerCall: Codable {
    var call: String
    var services: [String]
}

/// One interactor method reached from a VC action, with everything it fans out to.
struct ResolvedInteractorCall: Codable {
    var interactorMethod: String
    var services: [String]
    var workers: [ResolvedWorkerCall]
    var routes: [String]
}

/// One @IBAction / @objc function found on a ViewController (or its rx.tap-bound sibling),
/// with the full call chain resolved: VC action -> interactor method(s) -> worker/service calls -> router navigation.
struct ActionChain: Codable {
    var action: String
    var kind: String // "ibaction" | "objc" | "func" | "rxBinding"
    var file: String
    var calls: [ResolvedInteractorCall]
    var vcRoutes: [String] // router?.routeToXxx() called directly from the VC action, bypassing the interactor
    /// Enum-case shorthand (`.CaseName`) tokens found in the action body — this is how many scenes here signal
    /// *which* screen to show next: the VC emits an Output case, and the sibling Flow/*.swift file (not this
    /// scene folder) owns the actual `case .X: showNext(type: NextVC.self)` mapping. See FlowParser.swift.
    var emittedCases: [String]
    /// `emittedCases` resolved to a human destination, when a --flow-file was supplied and its create<VC>()
    /// switch could be matched. Empty when no flow file was given or no case matched.
    var resolvedDestinations: [String]
}

/// One backend endpoint, resolved from an API-router enum-of-functions file (e.g. MyRouter.swift).
struct ApiEndpoint: Codable {
    var caseName: String
    var path: String
    var method: String
    /// Service class the scene actually calls, when the endpoint was reached through one.
    var service: String = ""
    /// Request/response model type names, read from `BaseService<API, Request, Response>`.
    /// Empty when the service does not follow that generic shape.
    var requestType: String = ""
    var responseType: String = ""
}

/// Full HLD for one module — multiple scenes bundled into one file for the Figma plugin.
struct HLDBundle: Codable {
    var module: String
    var scenes: [SceneResult]
}

/// Full analysis of one CleanSwift/VIP scene directory.
struct SceneResult: Codable {
    var id: String
    var name: String
    var module: String
    /// Journey this scene belongs to — the folder directly under `Scenes/`, e.g. `AddMoney` for
    /// `Scenes/AddMoney/ViaCasa/…`. Renderers group by this so a 99-screen module reads as ~19
    /// journeys instead of one endless row. Assigned by main.swift, which knows the source path.
    var group: String = ""
    var viewControllers: [String]
    var interactors: [String]
    var presenters: [String]
    var routers: [String]
    var workers: [String]
    var routesTo: [String] // routeTo<X> function names defined on this scene's Router
    var servicesUsed: [String]
    var actionChains: [ActionChain]
    var xibs: [StoryboardResult]
    var apiEndpoints: [ApiEndpoint] // resolved only when --api-router is supplied and a service call matches a case
}
