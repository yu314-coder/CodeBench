import UIKit

/// VS Code IntelliSense-style completion system for the iOS code editor.
/// Raw values match LSP `CompletionItemKind` spec.
enum CompletionKind: Int {
    case text = 1
    case method = 2
    case function = 3
    case constructor = 4
    case field = 5
    case variable = 6
    case `class` = 7
    case interface = 8
    case module = 9
    case property = 10
    case unit = 11
    case value = 12
    case `enum` = 13
    case keyword = 14
    case snippet = 15
    case color = 16
    case file = 17
    case reference = 18
    case folder = 19
    case enumMember = 20
    case constant = 21
    case structure = 22
    case event = 23
    case `operator` = 24
    case typeParameter = 25

    /// SF Symbol name for this kind. Mirrors the VS Code icon set.
    var sfSymbol: String {
        switch self {
        case .function, .method:        return "f.square.fill"
        case .class, .structure:        return "c.square.fill"
        case .constructor:              return "wrench.and.screwdriver.fill"
        case .module:                   return "shippingbox.fill"
        case .variable, .field:         return "v.square.fill"
        case .property:                 return "circle.grid.3x3.fill"
        case .constant, .enumMember:    return "lock.square.fill"
        case .keyword:                  return "k.square.fill"
        case .enum:                     return "e.square.fill"
        case .snippet:                  return "scroll.fill"
        case .value, .unit:             return "number.square.fill"
        case .interface:                return "i.square.fill"
        case .reference, .file:         return "doc.text.fill"
        case .folder:                   return "folder.fill"
        case .operator:                 return "plusminus.circle.fill"
        case .typeParameter:            return "t.square.fill"
        case .text:                     return "textformat"
        case .event:                    return "bolt.fill"
        case .color:                    return "paintpalette.fill"
        }
    }

    /// Tint color for the icon, mirroring VS Code Dark+ kind colors.
    var tintColor: UIColor {
        switch self {
        case .function, .method:        return UIColor(red: 0.76, green: 0.56, blue: 0.95, alpha: 1) // purple
        case .class, .structure:        return UIColor(red: 0.93, green: 0.73, blue: 0.38, alpha: 1) // orange
        case .constructor:              return UIColor(red: 0.93, green: 0.73, blue: 0.38, alpha: 1) // orange
        case .module:                   return UIColor(red: 0.55, green: 0.80, blue: 0.55, alpha: 1) // green
        case .keyword:                  return UIColor(red: 0.95, green: 0.55, blue: 0.55, alpha: 1) // red
        case .constant, .enumMember:    return UIColor(red: 0.55, green: 0.80, blue: 0.95, alpha: 1) // cyan
        case .variable, .field:         return UIColor(red: 0.45, green: 0.72, blue: 0.98, alpha: 1) // blue
        case .property:                 return UIColor(red: 0.45, green: 0.72, blue: 0.98, alpha: 1) // blue
        case .enum:                     return UIColor(red: 0.55, green: 0.80, blue: 0.95, alpha: 1) // cyan
        case .snippet:                  return UIColor(red: 0.90, green: 0.85, blue: 0.55, alpha: 1) // yellow
        case .interface:                return UIColor(red: 0.55, green: 0.80, blue: 0.95, alpha: 1) // cyan
        default:                        return UIColor(white: 0.70, alpha: 1)
        }
    }

    /// Short label for sort prioritization (keywords first, then variables, then functions, etc.)
    var sortPriority: Int {
        switch self {
        case .keyword:                  return 1
        case .variable, .field, .property: return 2
        case .function, .method:        return 3
        case .class, .structure:        return 4
        case .constant, .enumMember:    return 5
        case .module:                   return 6
        default:                        return 7
        }
    }
}

/// A single completion suggestion, mirroring VS Code's CompletionItem.
struct CompletionItem {
    /// What the user sees in the list (e.g. "array")
    let label: String
    /// Category — drives icon, color, sorting
    let kind: CompletionKind
    /// Short right-aligned annotation (e.g. "numpy", "(keyword)")
    let detail: String
    /// What gets inserted on commit (usually == label)
    let insertText: String
    /// Module name for resolve (e.g. "numpy" for np.array)
    let module: String?

    // Resolve-phase fields — populated lazily
    var documentation: String? = nil
    var signature: String? = nil

    init(label: String, kind: CompletionKind, detail: String, insertText: String? = nil, module: String? = nil) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.insertText = insertText ?? label
        self.module = module
    }
}

/// The IntelliSense engine. Provides fast completion lists (Swift-only) and
/// lazy resolve (Python daemon via signal-file IPC).
final class IntelliSenseEngine {

    static let shared = IntelliSenseEngine()

    private init() {
        ensureSignalDir()
    }

    // MARK: - Signal-file IPC

    private let signalDirName = "intellisense_signals"

    private var signalDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(signalDirName)
    }

    private func ensureSignalDir() {
        try? FileManager.default.createDirectory(at: signalDir, withIntermediateDirectories: true)
    }

    // MARK: - Resolve (docstrings + signatures, async)

    /// Resolve a completion item's docstring and signature via the Python daemon.
    /// Non-blocking; fires `completion` on the main queue when done (or timeout).
    func resolve(_ item: CompletionItem, completion: @escaping (CompletionItem) -> Void) {
        guard let module = item.module else {
            completion(item)
            return
        }

        let id = UUID().uuidString
        let reqPayload: [String: Any] = [
            "id": id,
            "qualifier": module,
            "name": item.label,
        ]

        let reqURL = signalDir.appendingPathComponent("req_\(id).json")
        guard let reqData = try? JSONSerialization.data(withJSONObject: reqPayload) else {
            completion(item)
            return
        }
        try? reqData.write(to: reqURL, options: .atomic)

        let respURL = signalDir.appendingPathComponent("resp_\(id).json")

        // Poll for the response on a utility queue (not the main queue)
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<60 {  // 60 * 50ms = 3s timeout
                if FileManager.default.fileExists(atPath: respURL.path) {
                    var filled = item
                    if let data = try? Data(contentsOf: respURL),
                       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        filled.documentation = json["documentation"] as? String
                        filled.signature = json["signature"] as? String
                    }
                    try? FileManager.default.removeItem(at: respURL)
                    DispatchQueue.main.async { completion(filled) }
                    return
                }
                usleep(50_000)  // 50ms
            }
            // Timeout: cleanup request if still present, return unresolved item
            try? FileManager.default.removeItem(at: reqURL)
            DispatchQueue.main.async { completion(item) }
        }
    }

    // MARK: - Quick classification of base-candidate strings

    /// Classify a keyword/builtin string into a completion kind.
    /// Used by `CodeEditorViewController` when merging keywords with index entries.
    static func classify(_ identifier: String, inModule module: String?) -> CompletionKind {
        // Known keywords
        if pythonKeywordSet.contains(identifier) { return .keyword }
        if cStyleKeywordSet.contains(identifier) { return .keyword }
        // Starts with uppercase → likely class
        if let first = identifier.first, first.isUppercase { return .class }
        // Contains `(` or ends with `()` → function
        if identifier.contains("(") || identifier.hasSuffix("()") { return .function }
        // ALL_CAPS → constant
        if identifier == identifier.uppercased() && identifier.count > 1 { return .constant }
        // Starts with # → snippet (preformatted block)
        if identifier.hasPrefix("#") || identifier.contains(" ") { return .snippet }
        // Default: function (most common for Python stdlib names)
        return module != nil ? .function : .variable
    }

    private static let pythonKeywordSet: Set<String> = [
        "def", "class", "if", "elif", "else", "for", "while", "return", "import",
        "from", "as", "in", "not", "and", "or", "try", "except", "with", "lambda",
        "True", "False", "None", "raise", "finally", "yield", "pass",
        "break", "continue", "del", "global", "nonlocal", "assert", "is", "async", "await"
    ]

    private static let cStyleKeywordSet: Set<String> = [
        "int", "float", "double", "char", "void", "if", "else", "for", "while",
        "do", "return", "struct", "enum", "typedef", "static", "const", "unsigned",
        "long", "short", "switch", "case", "break", "continue", "default", "auto",
        "register", "extern", "union", "public", "private", "protected", "virtual",
        "namespace", "template", "typename", "class", "new", "delete", "this",
        "true", "false", "nullptr", "bool", "try", "catch", "throw"
    ]
}
