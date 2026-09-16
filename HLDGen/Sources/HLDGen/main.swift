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
/// Repeatable. Service classes usually live in a shared framework outside the module, so their
/// location cannot be derived from the scene paths.
var serviceDirArgs: [String] = []

var i = 0
while i < args.count {
    switch args[i] {
    case "--module":   i += 1; if i < args.count { moduleName = args[i] }
    case "--api-dir":  i += 1; if i < args.count { apiDirArg = args[i] }
    case "--api-router": i += 1; if i < args.count { apiRouterArg = args[i] }
    case "--flow-file": i += 1; if i < args.count { flowFileArg = args[i] }
    case "--services-dir": i += 1; if i < args.count { serviceDirArgs.append(args[i]) }
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
let scanRoots = serviceDirArgs.isEmpty
    ? [apiDirArg].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
    : serviceDirArgs.map { URL(fileURLWithPath: $0) }
if !scanRoots.isEmpty {
    serviceEndpoints = resolveServiceEndpoints(scanRoots: scanRoots)
}

var flowBindings: [FlowScreenBinding] = []
if let flowFileArg {
    flowBindings = parseFlowScreenBindings(readFile(URL(fileURLWithPath: flowFileArg)))
}

// MARK: - Analyze all scene dirs

/// The journey a scene belongs to: the folder directly beneath the container that holds all screens
/// (`Scenes/` by convention, `Screen/` in some projects). `Scenes/AddMoney/ViaCasa/Confirm` and
/// `Scenes/AddMoney/MainScreen` both return `AddMoney`. Falls back to the parent folder, then the module.
func journeyGroup(for sceneDir: URL, module: String) -> String {
    let parts = sceneDir.pathComponents
    if let i = parts.lastIndex(where: { $0.caseInsensitiveCompare("Scenes") == .orderedSame
                                     || $0.caseInsensitiveCompare("Screen") == .orderedSame }),
       i + 1 < parts.count {
        return parts[i + 1]
    }
    let parent = sceneDir.deletingLastPathComponent().lastPathComponent
    return parent.isEmpty ? module : parent
}

var scenes: [SceneResult] = []
for sceneDirPath in sceneDirArgs {
    let sceneDirURL = URL(fileURLWithPath: sceneDirPath)
    guard FileManager.default.fileExists(atPath: sceneDirURL.path) else {
        FileHandle.standardError.write("warning: scene directory not found, skipping: \(sceneDirPath)\n".data(using: .utf8)!)
        continue
    }
    let sceneName = sceneDirURL.lastPathComponent
    var result = analyzeScene(module: moduleName, sceneName: sceneName, sceneDir: sceneDirURL,
                              serviceEndpoints: serviceEndpoints, flowBindings: flowBindings)
    result.group = journeyGroup(for: sceneDirURL, module: moduleName)
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
