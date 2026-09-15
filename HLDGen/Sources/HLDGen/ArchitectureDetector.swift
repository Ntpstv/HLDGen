import Foundation

enum Architecture {
    case cleanSwift   // *Interactor.swift + *Router.swift present
    case mvvm         // *ViewModel.swift present (no Interactor)
    case swiftUI      // View structs (struct * : View), no ViewController
    case mvc          // *ViewController.swift only
    case unknown
}

func detectArchitecture(in dir: URL) -> Architecture {
    let files = findSceneFiles(under: dir, extensions: ["swift"])
    var hasInteractor = false
    var hasRouter     = false
    var hasViewModel  = false
    var hasVC         = false
    var hasSwiftUIView = false

    for file in files {
        let name = file.lastPathComponent
        let src  = readFile(file)

        if name.contains("Interactor") { hasInteractor = true }
        if name.contains("Router") && !name.contains("Routing") { hasRouter = true }
        if name.contains("ViewModel") || name.contains("VM") { hasViewModel = true }
        if name.contains("ViewController") || name.contains("VC") { hasVC = true }

        // SwiftUI: struct Foo: View { ... }
        if src.contains(": View {") || src.contains(": View\n") { hasSwiftUIView = true }
    }

    if hasInteractor && hasRouter { return .cleanSwift }
    if hasSwiftUIView && !hasVC   { return .swiftUI }
    if hasViewModel               { return .mvvm }
    if hasVC                      { return .mvc }
    return .unknown
}
