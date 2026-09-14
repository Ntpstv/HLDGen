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
    return src.matches(pattern, options: [.dotMatchesLineSeparators]).map {
        ApiEndpoint(caseName: $0[1], path: $0[2], method: $0[3].uppercased())
    }
}

/// For a Service.swift file (a `BaseApi<Req, Resp>` / `BaseService<...>` subclass), find which
/// `<SomeRouter>.<caseName>(` it calls in `createUrlReq`, so we can attach the resolved endpoint later.
/// Returns (routerTypeName, caseName), e.g. ("MyRouter", "menuWhiteList").
func findRouterCall(in serviceSrc: String) -> (router: String, caseName: String)? {
    guard let m = serviceSrc.firstMatch(#"(\w+Router)\.(\w+)\s*\("#) else { return nil }
    return (m[1], m[2])
}
