import Foundation

// MARK: - CLI

/// hldgen <sceneDir> [<sceneDir> ...] --module <name> [--api-dir <path>] [--api-router <path>] [--flow-file <path>] [-o <output.json>]
///
/// Accepts one or more scene directories. When more than one is supplied the output is an
/// HLDBundle ({ "module": "...", "scenes": [...] }) rather than a bare SceneResult — but
/// a single scene is also wrapped in HLDBundle, so the output shape is always the same.
///
/// Example (CalendarApp):
///   swift run --package-path Tools/HLDGen hldgen \
///     Calendar \
///     --module CalendarApp \
///     -o Tools/bundle.json

func printUsageAndExit() -> Never {
    FileHandle.standardError.write("""
    hldgen — CleanSwift/VIP scene analyzer for HLD generation

    Usage:
      hldgen <sceneDir> [<sceneDir> ...] --module <ModuleName>
             [--api-dir <path>] [--api-router <path>] [--flow-file <path>]
             [-o out.json]

    Output is always an HLDBundle:
      { "module": "...", "scenes": [ <SceneResult>, ... ] }

    Example:
      swift run --package-path Tools/HLDGen hldgen \\
        Calendar \\
        --module CalendarApp \\
        -o Tools/bundle.json

    """.data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { printUsageAndExit() }

var sceneDirArgs: [String] = []
var moduleName = "UnknownModule"
var apiDirArg: String?
var apiRouterArg: String?
var flowFileArg: String?
var outputArg: String?

var i = 0
while i < args.count {
    switch args[i] {
    case "--module":   i += 1; if i < args.count { moduleName = args[i] }
    case "--api-dir":  i += 1; if i < args.count { apiDirArg = args[i] }
    case "--api-router": i += 1; if i < args.count { apiRouterArg = args[i] }
    case "--flow-file": i += 1; if i < args.count { flowFileArg = args[i] }
    case "-o", "--output": i += 1; if i < args.count { outputArg = args[i] }
    default:
        // All non-flag positional args are treated as scene dirs
        if !args[i].hasPrefix("-") { sceneDirArgs.append(args[i]) }
    }
    i += 1
}

guard !sceneDirArgs.isEmpty else { printUsageAndExit() }

// MARK: - Resolve service-class -> endpoint

var serviceEndpoints: [String: ApiEndpoint] = [:]
if let apiRouterArg, let apiDirArg {
    let endpointsByCase = Dictionary(uniqueKeysWithValues:
        parseApiRouterFile(URL(fileURLWithPath: apiRouterArg)).map { ($0.caseName, $0) })
    let apiDirURL = URL(fileURLWithPath: apiDirArg)
    for file in findFiles(under: apiDirURL, extensions: ["swift"]) {
        let src = readFile(file)
        guard let classMatch = src.firstMatch(#"class\s+(\w+Service)\b"#) else { continue }
        guard let call = findRouterCall(in: src),
              let endpoint = endpointsByCase[call.caseName] else { continue }
        serviceEndpoints[classMatch[1]] = endpoint
    }
}

var flowBindings: [FlowScreenBinding] = []
if let flowFileArg {
    flowBindings = parseFlowScreenBindings(readFile(URL(fileURLWithPath: flowFileArg)))
}

// MARK: - Analyze all scene dirs

var scenes: [SceneResult] = []
for sceneDirPath in sceneDirArgs {
    let sceneDirURL = URL(fileURLWithPath: sceneDirPath)
    guard FileManager.default.fileExists(atPath: sceneDirURL.path) else {
        FileHandle.standardError.write("warning: scene directory not found, skipping: \(sceneDirPath)\n".data(using: .utf8)!)
        continue
    }
    let sceneName = sceneDirURL.lastPathComponent
    let result = analyzeScene(module: moduleName, sceneName: sceneName, sceneDir: sceneDirURL,
                              serviceEndpoints: serviceEndpoints, flowBindings: flowBindings)
    scenes.append(result)
}

guard !scenes.isEmpty else {
    FileHandle.standardError.write("error: no valid scene directories found\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Encode as HLDBundle

let bundle = HLDBundle(module: moduleName, scenes: scenes)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try! encoder.encode(bundle)

if let outputArg {
    try! data.write(to: URL(fileURLWithPath: outputArg))
    FileHandle.standardError.write("wrote \(scenes.count) scene(s) → \(outputArg)\n".data(using: .utf8)!)
} else {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}
