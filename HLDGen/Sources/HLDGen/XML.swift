import Foundation

/// Minimal DOM tree (XMLParser is SAX-only) — just enough to port analyze_ios.py's
/// ElementTree-based storyboard/xib walk: tag, attributes, ordered children.
final class XMLNode {
    let tag: String
    let attributes: [String: String]
    var children: [XMLNode] = []
    weak var parent: XMLNode?

    init(tag: String, attributes: [String: String]) {
        self.tag = tag
        self.attributes = attributes
    }

    /// First direct child with this tag (mirrors ElementTree's `elem.find('tag')`).
    func firstChild(tag: String) -> XMLNode? {
        children.first { $0.tag == tag }
    }

    /// First direct child with this tag AND a matching attribute value
    /// (mirrors `elem.find('rect[@key="frame"]')`).
    func firstChild(tag: String, whereAttr key: String, equals value: String) -> XMLNode? {
        children.first { $0.tag == tag && $0.attributes[key] == value }
    }

    /// All descendants (including self) with this tag, depth-first (mirrors `root.iter('tag')`).
    func allDescendants(tag: String) -> [XMLNode] {
        var result: [XMLNode] = []
        if self.tag == tag { result.append(self) }
        for child in children { result.append(contentsOf: child.allDescendants(tag: tag)) }
        return result
    }

    func doubleAttr(_ key: String, default def: Double = 0) -> Double {
        attributes[key].flatMap(Double.init) ?? def
    }
}

private final class DOMBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(tag: elementName, attributes: attributeDict)
        if let top = stack.last {
            top.children.append(node)
            node.parent = top
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        stack.removeLast()
    }
}

func parseXMLDocument(at url: URL) -> XMLNode? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let parser = XMLParser(data: data)
    let builder = DOMBuilder()
    parser.delegate = builder
    guard parser.parse() else { return nil }
    return builder.root
}
