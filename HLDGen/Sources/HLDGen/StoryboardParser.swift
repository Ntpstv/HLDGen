import Foundation

/// Interface Builder tag -> (renderer type, color, fallback label). Ported from analyze_ios.py's XIB_TYPE_MAP.
private struct ElementMeta { let type: String; let color: String; let label: String }
private let xibTypeMap: [String: ElementMeta] = [
    "button":               ElementMeta(type: "button",   color: "#1f6feb", label: "Button"),
    "label":                ElementMeta(type: "label",    color: "#8b949e", label: "Label"),
    "textField":            ElementMeta(type: "input",    color: "#388bfd", label: "TextField"),
    "textView":             ElementMeta(type: "textarea", color: "#388bfd", label: "TextArea"),
    "imageView":            ElementMeta(type: "image",    color: "#3fb950", label: "Image"),
    "tableView":            ElementMeta(type: "list",     color: "#8957e5", label: "TableView"),
    "collectionView":       ElementMeta(type: "grid",     color: "#8957e5", label: "CollectionView"),
    "stackView":            ElementMeta(type: "stack",    color: "#30363d", label: "Stack"),
    "scrollView":           ElementMeta(type: "scroll",   color: "#21262d", label: "ScrollView"),
    "view":                 ElementMeta(type: "view",     color: "#21262d", label: "View"),
    "switch":               ElementMeta(type: "toggle",   color: "#1f6feb", label: "Switch"),
    "segmentedControl":     ElementMeta(type: "segment",  color: "#1f6feb", label: "SegmentedControl"),
    "activityIndicatorView":ElementMeta(type: "loader",   color: "#8b949e", label: "Loading"),
    "webView":              ElementMeta(type: "web",      color: "#3fb950", label: "WebView"),
    "pageControl":          ElementMeta(type: "pager",    color: "#8b949e", label: "PageControl"),
    "datePicker":           ElementMeta(type: "picker",   color: "#1f6feb", label: "DatePicker"),
    "pickerView":           ElementMeta(type: "picker",   color: "#1f6feb", label: "PickerView"),
    "slider":               ElementMeta(type: "slider",   color: "#1f6feb", label: "Slider"),
    "navigationBar":        ElementMeta(type: "navbar",   color: "#161b22", label: "NavigationBar"),
    "tabBar":               ElementMeta(type: "tabbar",   color: "#161b22", label: "TabBar"),
    "toolbar":              ElementMeta(type: "toolbar",  color: "#161b22", label: "Toolbar"),
]

private let containerTags: Set<String> = [
    "viewController", "tableViewController", "collectionViewController", "navigationController", "tabBarController",
]

/// Recursively parse one IB view element into a positioned wireframe node. Depth-limited like the Python original
/// to avoid pathological recursion on deeply nested stack views.
private func parseNode(_ elem: XMLNode, depth: Int = 0, maxDepth: Int = 6) -> WireNode? {
    guard depth <= maxDepth else { return nil }
    let tag = elem.tag

    let rect = elem.firstChild(tag: "rect", whereAttr: "key", equals: "frame")
    let x = rect?.doubleAttr("x") ?? 0
    let y = rect?.doubleAttr("y") ?? 0
    let w = rect?.doubleAttr("width") ?? 0
    let h = rect?.doubleAttr("height") ?? 0

    guard let meta = xibTypeMap[tag] else {
        if w == 0 && h == 0 { return nil }
        // Unknown container tag: recurse into its subviews and surface as a plain group.
        var kids: [WireNode] = []
        if let subviews = elem.firstChild(tag: "subviews") {
            for sv in subviews.children {
                if let n = parseNode(sv, depth: depth + 1, maxDepth: maxDepth) { kids.append(n) }
            }
        }
        guard !kids.isEmpty else { return nil }
        return WireNode(type: "group", color: "#21262d", label: "", x: x, y: y, w: w, h: h, actions: nil, children: kids)
    }

    var text = elem.attributes["text"] ?? elem.attributes["placeholder"] ?? elem.attributes["title"] ?? elem.attributes["userLabel"] ?? ""
    if text.isEmpty, let state = elem.firstChild(tag: "state", whereAttr: "key", equals: "normal") {
        text = state.attributes["title"] ?? ""
    }

    var actions: [String] = []
    if let connections = elem.firstChild(tag: "connections") {
        for conn in connections.children where conn.tag == "action" {
            let sel = conn.attributes["selector"] ?? ""
            actions.append(sel.hasSuffix(":") ? String(sel.dropLast()) : sel)
        }
    }

    var children: [WireNode] = []
    if let subviews = elem.firstChild(tag: "subviews") {
        for sv in subviews.children {
            if let n = parseNode(sv, depth: depth + 1, maxDepth: maxDepth) { children.append(n) }
        }
    }

    return WireNode(
        type: meta.type, color: meta.color, label: text.isEmpty ? meta.label : text,
        x: x, y: y, w: w, h: h,
        actions: actions.isEmpty ? nil : actions,
        children: children
    )
}

private func findRootView(_ objects: XMLNode) -> XMLNode? {
    for elem in objects.children {
        if elem.tag == "view" { return elem }
        if containerTags.contains(elem.tag), let v = elem.firstChild(tag: "view") { return v }
    }
    return nil
}

private struct ObjectsBlockResult {
    var width: Double = 375
    var height: Double = 667
    var nodes: [WireNode] = []
    var outlets: [String] = []
    var actions: [String] = []
}

/// Shared XIB/storyboard-scene logic: IBOutlets/IBActions declared at the top level, plus the root view's
/// positioned subview tree.
private func parseObjectsBlock(_ objects: XMLNode) -> ObjectsBlockResult {
    var result = ObjectsBlockResult()

    for elem in objects.children {
        guard let connections = elem.firstChild(tag: "connections") else { continue }
        for conn in connections.children {
            if conn.tag == "outlet", let prop = conn.attributes["property"] { result.outlets.append(prop) }
            else if conn.tag == "action" {
                let sel = conn.attributes["selector"] ?? ""
                result.actions.append(sel.hasSuffix(":") ? String(sel.dropLast()) : sel)
            }
        }
    }

    if let rootView = findRootView(objects) {
        if let rect = rootView.firstChild(tag: "rect", whereAttr: "key", equals: "frame") {
            result.width = rect.doubleAttr("width", default: 375)
            result.height = rect.doubleAttr("height", default: 667)
        }
        if let subviews = rootView.firstChild(tag: "subviews") {
            for sv in subviews.children {
                if let node = parseNode(sv) { result.nodes.append(node) }
            }
        }
    }
    return result
}

func parseXibFile(_ url: URL) -> StoryboardResult? {
    guard let root = parseXMLDocument(at: url), let objects = root.firstChild(tag: "objects") else { return nil }
    let r = parseObjectsBlock(objects)
    guard !r.nodes.isEmpty || !r.outlets.isEmpty else { return nil }
    return StoryboardResult(source: "xib", vcClass: nil, file: url.lastPathComponent,
                             width: r.width, height: r.height, nodes: r.nodes, outlets: r.outlets, actions: r.actions)
}

func parseStoryboardFile(_ url: URL) -> [StoryboardResult] {
    guard let root = parseXMLDocument(at: url) else { return [] }
    var results: [StoryboardResult] = []
    for scene in root.allDescendants(tag: "scene") {
        guard let objects = scene.firstChild(tag: "objects") else { continue }
        guard let vcElem = objects.children.first(where: {
            ["viewController", "tableViewController", "collectionViewController"].contains($0.tag)
        }) else { continue }
        let vcClass = vcElem.attributes["customClass"] ?? vcElem.tag
        let r = parseObjectsBlock(objects)
        guard !r.nodes.isEmpty || !r.outlets.isEmpty else { continue }
        results.append(StoryboardResult(source: "storyboard", vcClass: vcClass, file: "\(url.lastPathComponent) (\(vcClass))",
                                         width: r.width, height: r.height, nodes: r.nodes, outlets: r.outlets, actions: r.actions))
    }
    return results
}

/// Find and parse every .xib/.storyboard directly under a scene directory.
func parseSceneStoryboards(in sceneDir: URL) -> [StoryboardResult] {
    var results: [StoryboardResult] = []
    for xib in findFiles(under: sceneDir, extensions: ["xib"]) {
        if let r = parseXibFile(xib) { results.append(r) }
    }
    for sb in findFiles(under: sceneDir, extensions: ["storyboard"]) {
        results.append(contentsOf: parseStoryboardFile(sb))
    }
    return results
}
