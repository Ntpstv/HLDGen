import Foundation

/// A scene calls a service, but the path and HTTP method live two hops away, usually in a
/// different framework entirely:
///
///     // PTCoreServices
///     class PTPProfileHomeService: BaseService<PTPProfileHomeAPI, PTPProfileHomeRequest, PTPProfileHomeResponse>
///     class PTPProfileHomeAPI: BaseAPI<…> { … Router.ptPayProfileHome(parameters:) … }
///     // KPayCustomerDataRepository
///     enum Router { case ptPayProfileHome; var path: String { "/paotang/v1/…" } }
///
/// Resolving only the first hop, inside the module's own API folder, finds nothing: the module's
/// router is not the one its services reach. So the scan is repo-wide and the join is keyed by
/// `RouterType.caseName` — two routers in a large app routinely share a case name.
struct ServiceBinding {
    var api: String
    var requestType: String
    var responseType: String
}

/// Every router case in the tree, keyed `RouterType.caseName`.
func parseAllRouters(in dirs: [URL]) -> [String: ApiEndpoint] {
    var endpoints: [String: ApiEndpoint] = [:]
    for dir in dirs {
        for file in findFiles(under: dir, extensions: ["swift"]) {
            guard file.lastPathComponent.hasSuffix("Router.swift") else { continue }
            let src = readFile(file)
            let routerType = src.firstMatch(#"(?:enum|struct|class)\s+(\w*Router)\b"#)?[1]
                ?? file.deletingPathExtension().lastPathComponent
            for endpoint in parseApiRouterFile(file) {
                let key = "\(routerType).\(endpoint.caseName)"
                if endpoints[key] == nil { endpoints[key] = endpoint }
            }
        }
    }
    return endpoints
}

/// Maps each `*Service` class to the API type and request/response models it declares.
func parseServiceBindings(in dirs: [URL]) -> [String: ServiceBinding] {
    var bindings: [String: ServiceBinding] = [:]
    for dir in dirs {
        for file in findFiles(under: dir, extensions: ["swift"]) {
            let src = readFile(file)
            guard src.contains("BaseService<") else { continue }   // cheap reject before regex
            for m in src.matches(#"class\s+(\w+)\s*:\s*\w*BaseService\s*<([^>]+)>"#) {
                let args = m[2].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard args.count >= 3 else { continue }
                bindings[m[1]] = ServiceBinding(api: args[0],
                                                requestType: args[1],
                                                responseType: args[2])
            }
        }
    }
    return bindings
}

/// Maps each API class to the `RouterType.caseName` it calls. Any type name is accepted — these
/// are suffixed `API` in one framework and `Service` in another, and demanding one suffix
/// resolved zero endpoints.
func parseApiClassRouterCalls(in dirs: [URL]) -> [String: String] {
    var calls: [String: String] = [:]
    for dir in dirs {
        for file in findFiles(under: dir, extensions: ["swift"]) {
            let src = readFile(file)
            guard src.contains("Router.") else { continue }        // cheap reject before regex
            guard let decl = src.firstMatch(#"(?:class|struct|enum)\s+(\w+)"#),
                  let call = findRouterCall(in: src) else { continue }
            calls[decl[1]] = "\(call.router).\(call.caseName)"
        }
    }
    return calls
}

/// Joins every layer into the lookup the analysers use: service class name → endpoint.
/// One walk, reading each file once — four separate passes over a 15,000-file repo is four times
/// the I/O for the same answer.
func resolveServiceEndpoints(scanRoots: [URL]) -> [String: ApiEndpoint] {
    var endpoints: [String: ApiEndpoint] = [:]   // "RouterType.caseName" → endpoint
    var bindings:  [String: ServiceBinding] = [:]
    var apiCalls:  [String: String] = [:]        // api class → "RouterType.caseName"
    var models:    [String: ModelDef] = [:]

    for root in scanRoots {
        for file in findFiles(under: root, extensions: ["swift"]) {
            let src = readFile(file)

            if file.lastPathComponent.hasSuffix("Router.swift") {
                let routerType = src.firstMatch(#"(?:enum|struct|class)\s+(\w*Router)\b"#)?[1]
                    ?? file.deletingPathExtension().lastPathComponent
                for endpoint in parseApiRouterFile(file) {
                    let key = "\(routerType).\(endpoint.caseName)"
                    if endpoints[key] == nil { endpoints[key] = endpoint }
                }
            }

            if src.contains("BaseService<") {
                for m in src.matches(#"class\s+(\w+)\s*:\s*\w*BaseService\s*<([^>]+)>"#) {
                    let args = m[2].split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    guard args.count >= 3 else { continue }
                    bindings[m[1]] = ServiceBinding(api: args[0],
                                                    requestType: args[1],
                                                    responseType: args[2])
                }
            }

            if src.contains("Router."),
               let decl = src.firstMatch(#"(?:class|struct|enum)\s+(\w+)"#),
               let call = findRouterCall(in: src) {
                apiCalls[decl[1]] = "\(call.router).\(call.caseName)"
            }

            for (name, def) in parseModels(in: src) where models[name] == nil {
                models[name] = def
            }
        }
    }

    var resolved: [String: ApiEndpoint] = [:]
    for (service, binding) in bindings {
        guard let key = apiCalls[binding.api],
              var endpoint = endpoints[key] else { continue }
        endpoint.service       = service
        endpoint.requestType   = binding.requestType
        endpoint.responseType  = binding.responseType
        endpoint.requestFields  = fieldsFor(binding.requestType, in: models)
        endpoint.responseFields = fieldsFor(binding.responseType, in: models)
        resolved[service] = endpoint
    }

    // Types that reach the router directly, with no separate API class in between.
    for (type, key) in apiCalls where resolved[type] == nil {
        guard var endpoint = endpoints[key] else { continue }
        endpoint.service = type
        resolved[type] = endpoint
    }

    FileHandle.standardError.write("""
    api graph: \(endpoints.count) router cases · \(bindings.count) services · \
    \(apiCalls.count) api classes → \(resolved.count) endpoints resolved

    """.data(using: .utf8)!)
    return resolved
}
