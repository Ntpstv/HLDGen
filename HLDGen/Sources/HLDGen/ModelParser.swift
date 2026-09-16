import Foundation

/// A request/response model, as declared in source.
struct ModelDef {
    var fields: [ApiField]
    /// Type name of a lone `content` wrapper, e.g. `class FooResponse { var content: FooContent? }`.
    /// The payload worth showing lives one level down in that case.
    var contentType: String?
}

/// Parses ObjectMapper and Codable models out of one file.
///
///     open class FooResponseContent: Mappable {
///         public var greetingText: String?
///         public func mapping(map: Map) { greetingText <- map["greeting_text"] }
///     }
///
/// Property declarations give the names and types; `mapping(map:)` gives the JSON keys where they
/// differ. Computed properties are skipped — a `var x: T { … }` is not part of the payload.
func parseModels(in src: String) -> [String: ModelDef] {
    var models: [String: ModelDef] = [:]

    let decl = #"(?:open|public|final|internal|private)?\s*(?:class|struct)\s+(\w+)\s*:\s*([^{]+)\{"#
    for (m, start) in src.matchesWithRange(decl) {
        let name = m[1]
        let conformances = m[2]
        // Base classes vary by framework — BaseResponseModel, BaseRequestDataModel, and so on —
        // so any `*Model` superclass counts alongside the serialisation protocols. Matching
        // exact names missed `BaseRequestDataModel` and left those payloads unparsed.
        guard conformances.contains("Mappable")
           || conformances.contains("Codable")
           || conformances.contains("Decodable")
           || conformances.contains("Encodable")
           || conformances.firstMatch(#"\b\w*Model\b"#) != nil
        else { continue }

        guard let openBrace = src.range(of: "{", range: start..<src.endIndex),
              let body = bracedRange(from: openBrace.lowerBound, in: src)
        else { continue }

        var fields: [ApiField] = []
        var seen = Set<String>()
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            // A trailing `{` means a computed property or an accessor block, not stored data.
            guard !trimmed.hasSuffix("{") else { continue }
            guard let f = trimmed.firstMatch(#"^(?:public|open|private|internal|fileprivate)?\s*(?:var|let)\s+(\w+)\s*:\s*([^=]+?)\s*$"#)
            else { continue }
            let fieldName = f[1]
            guard !seen.contains(fieldName) else { continue }
            seen.insert(fieldName)
            fields.append(ApiField(json: fieldName,
                                   type: f[2].trimmingCharacters(in: .whitespaces)))
        }

        // ObjectMapper renames on the wire; prefer the mapped key over the property name.
        var renames: [String: String] = [:]
        for r in body.matches(#"(\w+)\s*<-\s*map\[\"([^\"]+)\"\]"#) { renames[r[1]] = r[2] }
        // Codable does the same through CodingKeys.
        for r in body.matches(#"case\s+(\w+)\s*=\s*\"([^\"]+)\""#) { renames[r[1]] = r[2] }
        fields = fields.map {
            var f = $0
            if let mapped = renames[f.json] { f.json = mapped }
            return f
        }

        let contentType = fields.count == 1 && fields[0].json == "content"
            ? bareTypeName(fields[0].type)
            : nil
        models[name] = ModelDef(fields: fields, contentType: contentType)
    }
    return models
}

/// Fields worth showing for `typeName`, following a single `content` wrapper when the model is one.
func fieldsFor(_ typeName: String, in models: [String: ModelDef], limit: Int = 12) -> [ApiField] {
    guard let model = models[bareTypeName(typeName)] else { return [] }
    if let content = model.contentType, let inner = models[content] {
        return Array(inner.fields.prefix(limit))
    }
    return Array(model.fields.prefix(limit))
}

/// Strips optionality and array/collection wrappers: `[FooContent]?` → `FooContent`.
func bareTypeName(_ type: String) -> String {
    var t = type.trimmingCharacters(in: .whitespaces)
    while t.hasSuffix("?") || t.hasSuffix("!") { t.removeLast() }
    if t.hasPrefix("["), t.hasSuffix("]") {
        t = String(t.dropFirst().dropLast())
        if let colon = t.firstIndex(of: ":") { t = String(t[t.index(after: colon)...]) }  // [K: V] → V
    }
    return t.trimmingCharacters(in: .whitespaces)
}

/// Text between the brace at `open` and its match.
private func bracedRange(from open: String.Index, in src: String) -> String? {
    var depth = 0
    var i = open
    while i < src.endIndex {
        if src[i] == "{" { depth += 1 }
        else if src[i] == "}" {
            depth -= 1
            if depth == 0 { return String(src[src.index(after: open)..<i]) }
        }
        i = src.index(after: i)
    }
    return nil
}
