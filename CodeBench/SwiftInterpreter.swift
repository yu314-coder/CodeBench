import Foundation

/// Pure-Swift tree-walking interpreter for a useful subset of Swift.
/// Runs on-device with no JIT (App Store safe). Companion to the
/// existing C / C++ / Fortran interpreters.
///
/// SUPPORTED (tier 2 — ~80 % of teaching/scripting Swift):
///   • Literals: Int, Double, String (with interpolation), Bool, nil
///   • Variables: `let` and `var` with type-inference or explicit types
///   • Operators: arithmetic, comparison, logical, ternary, nil-coalesce
///   • Control flow: `if` / `else` / `else if`, `while`, `repeat-while`,
///                   `for x in seq`, `switch` w/ cases + `default`,
///                   `break`, `continue`, `guard`
///   • Functions: `func name(p: T) -> T { … }` w/ default args + return
///   • Closures: `{ x in x * 2 }` + shorthand `{ $0 * 2 }`
///   • Arrays: `[1, 2, 3]`, subscript, `.count`, `.append(_)`, `.map`,
///             `.filter`, `.reduce`, `.first` / `.last`
///   • Dictionaries: `[k: v]`, subscript (returns Optional)
///   • Tuples: `(a, b, c)` + destructuring `let (x, y) = pair`
///   • Optionals: `T?`, `nil`, force-unwrap `!`, optional binding
///                via `if let` / `guard let`, `??`
///   • String interpolation: `"\(expr)"`
///   • Ranges: `0..<10`, `0...10`
///   • Built-ins: `print`, `Int(…)`, `Double(…)`, `String(…)`, `Bool(…)`,
///                `abs`, `min`, `max`, `sqrt`, `pow`, type init parsing
///                from String returning Optional
///
/// NOT SUPPORTED (would need tier 3):
///   • struct / class / enum declarations (basic struct can be added later)
///   • Protocols, generics, extensions
///   • try / throw / do-catch, async/await, actors
///   • `import` of real frameworks (the interpreter exposes only its
///     own built-in stdlib subset)
///   • Reflection (`Mirror`), `Codable`, KVC
///   • Native runtime interop (UIKit, SwiftUI, Foundation classes)
///
/// USAGE:
///   let result = SwiftInterpreter.shared.execute(sourceText)
///   print(result.output, result.error ?? "")

// MARK: - Public Runtime Wrapper

final class SwiftRuntime {
    static let shared = SwiftRuntime()
    private init() {}

    struct ExecutionResult {
        let output: String
        let error: String?
        let success: Bool
    }

    func execute(_ source: String) -> ExecutionResult {
        let interp = SwiftInterpreter()
        do {
            try interp.run(source)
            return ExecutionResult(output: interp.outputBuffer,
                                   error: nil, success: true)
        } catch let err as SwiftInterpreter.RuntimeError {
            return ExecutionResult(output: interp.outputBuffer,
                                   error: err.formatted, success: false)
        } catch {
            return ExecutionResult(output: interp.outputBuffer,
                                   error: "Internal error: \(error)",
                                   success: false)
        }
    }
}

// MARK: - C ABI bridge for the Python terminal
//
// Python's `swift file.swift` builtin reaches these via
// `ctypes.CDLL(None)` — same pattern as cb_metal_* / cb_bg_*.
// Result is a JSON blob:
//   {"success": true|false, "output": "...", "error": "..."}
// The caller is responsible for `cb_swift_free`'ing the returned
// pointer; we use `strdup` so the buffer outlives the Swift String's
// stack lifetime.

@_cdecl("cb_swift_execute")
public func cb_swift_execute(
    _ source: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let source else { return strdup("{\"success\":false,\"output\":\"\",\"error\":\"null source\"}") }
    let src = String(cString: source)
    let r = SwiftRuntime.shared.execute(src)
    // Hand-build the JSON — output / error can contain almost
    // anything (incl. raw newlines + UTF-8) so we escape per spec.
    func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        for c in s.unicodeScalars {
            switch c {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out
    }
    let json = "{\"success\":\(r.success),\"output\":\"\(esc(r.output))\",\"error\":\"\(esc(r.error ?? ""))\"}"
    return strdup(json)
}

@_cdecl("cb_swift_free")
public func cb_swift_free(_ ptr: UnsafeMutablePointer<CChar>?) {
    guard let ptr else { return }
    free(ptr)
}

/// Force-link the @_cdecl entry points above. Same dead-strip-defeat
/// trick as `_cbMetalBridgeKeepAlive` / `_cbBackgroundKeepAlive`:
/// a hard call site keeps the dynamic-symbol export entries from
/// being elided in Release builds. Invoked from a static let in
/// AppDelegate so it runs once at launch.
public func _cbSwiftBridgeKeepAlive() -> Int {
    // Pass an empty program — runs the tokenizer + parser on "" and
    // returns success, no side effects. Returned pointer is non-nil
    // (strdup of a JSON blob); we free it immediately.
    var sentinel: Int = 0
    "".withCString { ptr in
        if let p = cb_swift_execute(ptr) {
            sentinel = Int(bitPattern: UnsafePointer<CChar>(p)) & 0x1
            cb_swift_free(p)
        }
    }
    return sentinel
}

// MARK: - SwiftInterpreter

final class SwiftInterpreter {

    var outputBuffer: String = ""
    private var globalEnv = Environment()

    // ────────────────────────────────────────────────────────────
    // Entry point
    // ────────────────────────────────────────────────────────────
    func run(_ source: String) throws {
        let tokens = try Tokenizer(source: source).tokenize()
        let parser = Parser(tokens: tokens)
        let statements = try parser.parseProgram()
        installBuiltins()
        for stmt in statements {
            _ = try execute(stmt, env: globalEnv)
        }
    }

    // MARK: - Errors

    struct RuntimeError: Error {
        let message: String
        let line: Int
        var formatted: String { "Line \(line): \(message)" }
    }

    private func runtimeError(_ msg: String, line: Int = 0) -> RuntimeError {
        return RuntimeError(message: msg, line: line)
    }

    // MARK: - Value type
    //
    // Single enum covers every Swift value the interpreter knows
    // how to represent. Heap-y collections (Array, Dictionary,
    // String) are passed by-reference via class-wrapping so user
    // code sees Swift-correct value-vs-reference semantics for the
    // built-in types. Arrays in Swift ARE value types but mutations
    // through `var` need to be visible to the variable's binding —
    // wrapping with a class lets `arr.append(x)` mutate in place
    // without complex copy-on-write tracking.

    indirect enum Value {
        case int(Int)
        case double(Double)
        case bool(Bool)
        case string(String)
        case array(ArrayRef)
        case dictionary(DictRef)
        case tuple([Value])
        case range(Int, Int, Bool)            // (lo, hi, closed)
        case `nil`
        case function(FunctionDecl, Environment) // closure: decl + captured env
        case builtin(BuiltinFn)

        var typeName: String {
            switch self {
            case .int: return "Int"
            case .double: return "Double"
            case .bool: return "Bool"
            case .string: return "String"
            case .array: return "Array"
            case .dictionary: return "Dictionary"
            case .tuple(let xs): return "(\(xs.map { $0.typeName }.joined(separator: ", ")))"
            case .range: return "Range"
            case .nil: return "Optional<nil>"
            case .function, .builtin: return "Function"
            }
        }

        var swiftDescription: String {
            switch self {
            case .int(let n): return String(n)
            case .double(let d):
                // Swift prints integral Doubles with `.0`; match that.
                if d == d.rounded() && abs(d) < 1e16 {
                    return String(format: "%.1f", d)
                }
                return String(d)
            case .bool(let b): return b ? "true" : "false"
            case .string(let s): return s
            case .array(let a):
                return "[" + a.values.map { $0.literalRepr() }.joined(separator: ", ") + "]"
            case .dictionary(let d):
                let pairs = d.entries.map { "\($0.0.literalRepr()): \($0.1.literalRepr())" }
                return "[" + (pairs.isEmpty ? ":" : pairs.joined(separator: ", ")) + "]"
            case .tuple(let xs):
                return "(" + xs.map { $0.literalRepr() }.joined(separator: ", ") + ")"
            case .range(let lo, let hi, let closed):
                return "\(lo)\(closed ? "..." : "..<")\(hi)"
            case .nil: return "nil"
            case .function, .builtin: return "(Function)"
            }
        }

        /// Like swiftDescription but Strings are quoted (used inside
        /// arrays/dicts so output matches Swift's standard).
        func literalRepr() -> String {
            if case .string(let s) = self { return "\"\(s)\"" }
            return swiftDescription
        }
    }

    final class ArrayRef {
        var values: [Value]
        init(_ values: [Value]) { self.values = values }
    }

    final class DictRef {
        // Use an array of pairs to preserve insertion order (Swift
        // Dictionary doesn't, but the interpreter's output reads
        // better this way).
        var entries: [(Value, Value)] = []
        func get(_ key: Value) -> Value? {
            for (k, v) in entries {
                if valuesEqual(k, key) { return v }
            }
            return nil
        }
        func set(_ key: Value, _ value: Value) {
            for i in 0..<entries.count {
                if valuesEqual(entries[i].0, key) {
                    entries[i].1 = value
                    return
                }
            }
            entries.append((key, value))
        }
        private func valuesEqual(_ a: Value, _ b: Value) -> Bool {
            switch (a, b) {
            case (.int(let x), .int(let y)): return x == y
            case (.double(let x), .double(let y)): return x == y
            case (.string(let x), .string(let y)): return x == y
            case (.bool(let x), .bool(let y)): return x == y
            default: return false
            }
        }
    }

    typealias BuiltinFn = ([Value]) throws -> Value

    // MARK: - Environment (scope chain)

    final class Environment {
        var vars: [String: Value] = [:]
        var consts: Set<String> = []
        weak var parent: Environment?

        init(parent: Environment? = nil) { self.parent = parent }

        func define(_ name: String, value: Value, isConst: Bool) {
            vars[name] = value
            if isConst { consts.insert(name) }
        }

        func get(_ name: String) -> Value? {
            if let v = vars[name] { return v }
            return parent?.get(name)
        }

        func assign(_ name: String, value: Value) -> Bool {
            if vars[name] != nil {
                if consts.contains(name) { return false }
                vars[name] = value
                return true
            }
            return parent?.assign(name, value: value) ?? false
        }

        /// True if `name` is bound somewhere in the scope chain.
        func contains(_ name: String) -> Bool {
            if vars[name] != nil { return true }
            return parent?.contains(name) ?? false
        }
    }

    // ────────────────────────────────────────────────────────────
    //          TOKENIZER
    // ────────────────────────────────────────────────────────────

    enum TokenKind {
        case ident, number, string, stringInterpolation
        case lparen, rparen, lbrace, rbrace, lbracket, rbracket
        case comma, semicolon, colon, dot, dotDotLess, dotDotDot, arrow
        case eq, eqEq, bangEq, lt, gt, ltEq, gtEq, bang
        case plus, minus, star, slash, percent
        case plusEq, minusEq, starEq, slashEq
        case ampAmp, pipePipe, question, questionQuestion
        case keyword, eof
    }

    struct Token {
        let kind: TokenKind
        let lexeme: String
        let line: Int
        /// Numeric / string value for literals
        let literal: Value?
        /// For .stringInterpolation: pieces are (literal text, embedded expression source).
        let interpolationParts: [(String, String)]?
    }

    final class Tokenizer {
        private let source: [Character]
        private var pos = 0
        private var line = 1
        private static let keywords: Set<String> = [
            "let", "var", "if", "else", "while", "for", "in", "repeat",
            "switch", "case", "default", "break", "continue", "return",
            "func", "true", "false", "nil", "guard", "where", "do",
            "init", "self", "struct", "enum", "class", "extension",
            "protocol", "import", "public", "private", "internal",
            "fileprivate", "static", "override", "throws", "rethrows",
            "throw", "try", "as", "is", "Any", "Self",
        ]

        init(source: String) { self.source = Array(source) }

        func tokenize() throws -> [Token] {
            var tokens: [Token] = []
            while pos < source.count {
                let c = source[pos]
                if c == " " || c == "\t" || c == "\r" {
                    pos += 1; continue
                }
                if c == "\n" { line += 1; pos += 1; continue }

                // Comments
                if c == "/" && peek(1) == "/" {
                    while pos < source.count && source[pos] != "\n" { pos += 1 }
                    continue
                }
                if c == "/" && peek(1) == "*" {
                    pos += 2
                    while pos < source.count {
                        if source[pos] == "*" && peek(1) == "/" { pos += 2; break }
                        if source[pos] == "\n" { line += 1 }
                        pos += 1
                    }
                    continue
                }

                // Numbers
                if c.isNumber {
                    tokens.append(try scanNumber())
                    continue
                }
                // Identifiers / keywords
                if c.isLetter || c == "_" {
                    tokens.append(scanIdent())
                    continue
                }
                // Closure shorthand: $0, $1, $2, ... — Swift lets you
                // refer to closure arguments positionally without an
                // explicit parameter list. The numeric suffix is parsed
                // greedily; the result becomes an identifier token so
                // the regular `lookup(name:)` path can resolve it
                // against synthetic bindings the closure installs.
                if c == "$" {
                    let start = pos
                    pos += 1
                    while pos < source.count, source[pos].isNumber {
                        pos += 1
                    }
                    let lex = String(source[start..<pos])
                    tokens.append(Token(kind: .ident, lexeme: lex,
                                        line: line, literal: nil,
                                        interpolationParts: nil))
                    continue
                }
                // Strings
                if c == "\"" {
                    tokens.append(try scanString())
                    continue
                }
                tokens.append(try scanOperator())
            }
            tokens.append(Token(kind: .eof, lexeme: "", line: line,
                                literal: nil, interpolationParts: nil))
            return tokens
        }

        private func peek(_ off: Int) -> Character? {
            let i = pos + off
            return i < source.count ? source[i] : nil
        }

        private func scanNumber() throws -> Token {
            let start = pos
            var isDouble = false
            while pos < source.count, source[pos].isNumber || source[pos] == "_" {
                pos += 1
            }
            if pos < source.count, source[pos] == ".", peek(1)?.isNumber == true {
                isDouble = true
                pos += 1
                while pos < source.count, source[pos].isNumber || source[pos] == "_" {
                    pos += 1
                }
            }
            // Scientific notation
            if pos < source.count, source[pos] == "e" || source[pos] == "E" {
                isDouble = true
                pos += 1
                if pos < source.count, source[pos] == "+" || source[pos] == "-" {
                    pos += 1
                }
                while pos < source.count, source[pos].isNumber { pos += 1 }
            }
            let raw = String(source[start..<pos]).replacingOccurrences(of: "_", with: "")
            if isDouble {
                guard let d = Double(raw) else {
                    throw RuntimeError(message: "Invalid number literal '\(raw)'", line: line)
                }
                return Token(kind: .number, lexeme: raw, line: line,
                             literal: .double(d), interpolationParts: nil)
            } else {
                guard let n = Int(raw) else {
                    throw RuntimeError(message: "Invalid number literal '\(raw)'", line: line)
                }
                return Token(kind: .number, lexeme: raw, line: line,
                             literal: .int(n), interpolationParts: nil)
            }
        }

        private func scanIdent() -> Token {
            let start = pos
            while pos < source.count, source[pos].isLetter || source[pos].isNumber || source[pos] == "_" {
                pos += 1
            }
            let lex = String(source[start..<pos])
            if Tokenizer.keywords.contains(lex) {
                return Token(kind: .keyword, lexeme: lex, line: line,
                             literal: nil, interpolationParts: nil)
            }
            return Token(kind: .ident, lexeme: lex, line: line,
                         literal: nil, interpolationParts: nil)
        }

        private func scanString() throws -> Token {
            pos += 1   // skip opening "
            var parts: [(String, String)] = []
            var current = ""
            while pos < source.count, source[pos] != "\"" {
                let c = source[pos]
                if c == "\\" {
                    pos += 1
                    guard pos < source.count else {
                        throw RuntimeError(message: "Unterminated string", line: line)
                    }
                    switch source[pos] {
                    case "n": current += "\n"
                    case "t": current += "\t"
                    case "r": current += "\r"
                    case "\\": current += "\\"
                    case "\"": current += "\""
                    case "0": current += "\0"
                    case "(":   // interpolation
                        pos += 1
                        var depth = 1
                        var expr = ""
                        while pos < source.count, depth > 0 {
                            let cc = source[pos]
                            if cc == "(" { depth += 1 }
                            else if cc == ")" { depth -= 1; if depth == 0 { break } }
                            expr.append(cc)
                            pos += 1
                        }
                        guard pos < source.count, source[pos] == ")" else {
                            throw RuntimeError(message: "Unterminated string interpolation",
                                               line: line)
                        }
                        parts.append((current, expr))
                        current = ""
                    default: current.append(source[pos])
                    }
                    pos += 1
                } else {
                    if c == "\n" { line += 1 }
                    current.append(c)
                    pos += 1
                }
            }
            guard pos < source.count else {
                throw RuntimeError(message: "Unterminated string", line: line)
            }
            pos += 1   // skip closing "

            if parts.isEmpty {
                return Token(kind: .string, lexeme: current, line: line,
                             literal: .string(current), interpolationParts: nil)
            }
            // tail piece
            parts.append((current, ""))
            return Token(kind: .stringInterpolation, lexeme: "", line: line,
                         literal: nil, interpolationParts: parts)
        }

        private func scanOperator() throws -> Token {
            let c = source[pos]
            let nl = line
            switch c {
            case "(": pos += 1; return tok(.lparen, "(", nl)
            case ")": pos += 1; return tok(.rparen, ")", nl)
            case "{": pos += 1; return tok(.lbrace, "{", nl)
            case "}": pos += 1; return tok(.rbrace, "}", nl)
            case "[": pos += 1; return tok(.lbracket, "[", nl)
            case "]": pos += 1; return tok(.rbracket, "]", nl)
            case ",": pos += 1; return tok(.comma, ",", nl)
            case ";": pos += 1; return tok(.semicolon, ";", nl)
            case ":": pos += 1; return tok(.colon, ":", nl)
            case ".":
                if peek(1) == "." && peek(2) == "<" {
                    pos += 3; return tok(.dotDotLess, "..<", nl)
                }
                if peek(1) == "." && peek(2) == "." {
                    pos += 3; return tok(.dotDotDot, "...", nl)
                }
                pos += 1; return tok(.dot, ".", nl)
            case "+":
                if peek(1) == "=" { pos += 2; return tok(.plusEq, "+=", nl) }
                pos += 1; return tok(.plus, "+", nl)
            case "-":
                if peek(1) == ">" { pos += 2; return tok(.arrow, "->", nl) }
                if peek(1) == "=" { pos += 2; return tok(.minusEq, "-=", nl) }
                pos += 1; return tok(.minus, "-", nl)
            case "*":
                if peek(1) == "=" { pos += 2; return tok(.starEq, "*=", nl) }
                pos += 1; return tok(.star, "*", nl)
            case "/":
                if peek(1) == "=" { pos += 2; return tok(.slashEq, "/=", nl) }
                pos += 1; return tok(.slash, "/", nl)
            case "%": pos += 1; return tok(.percent, "%", nl)
            case "=":
                if peek(1) == "=" { pos += 2; return tok(.eqEq, "==", nl) }
                pos += 1; return tok(.eq, "=", nl)
            case "!":
                if peek(1) == "=" { pos += 2; return tok(.bangEq, "!=", nl) }
                pos += 1; return tok(.bang, "!", nl)
            case "<":
                if peek(1) == "=" { pos += 2; return tok(.ltEq, "<=", nl) }
                pos += 1; return tok(.lt, "<", nl)
            case ">":
                if peek(1) == "=" { pos += 2; return tok(.gtEq, ">=", nl) }
                pos += 1; return tok(.gt, ">", nl)
            case "&":
                if peek(1) == "&" { pos += 2; return tok(.ampAmp, "&&", nl) }
                pos += 1; throw RuntimeError(message: "Unexpected '&'", line: nl)
            case "|":
                if peek(1) == "|" { pos += 2; return tok(.pipePipe, "||", nl) }
                pos += 1; throw RuntimeError(message: "Unexpected '|'", line: nl)
            case "?":
                if peek(1) == "?" { pos += 2; return tok(.questionQuestion, "??", nl) }
                pos += 1; return tok(.question, "?", nl)
            default:
                pos += 1
                throw RuntimeError(message: "Unexpected character '\(c)'", line: nl)
            }
        }

        private func tok(_ k: TokenKind, _ s: String, _ l: Int) -> Token {
            return Token(kind: k, lexeme: s, line: l,
                         literal: nil, interpolationParts: nil)
        }
    }

    // ────────────────────────────────────────────────────────────
    //          AST
    // ────────────────────────────────────────────────────────────

    indirect enum Expression {
        case intLit(Int, Int)              // (value, line)
        case doubleLit(Double, Int)
        case stringLit(String, Int)
        case interpolation([(String, Expression?)], Int)   // text or embedded expr
        case boolLit(Bool, Int)
        case nilLit(Int)
        case identifier(String, Int)
        case binary(Expression, String, Expression, Int)
        case unary(String, Expression, Int)
        case assign(Expression, String, Expression, Int)   // op = "=", "+=", etc.
        case call(Expression, [Expression], [String?], Int)  // fn, args, labels
        case memberAccess(Expression, String, Int)
        case subscriptAccess(Expression, Expression, Int)
        case arrayLit([Expression], Int)
        case dictLit([(Expression, Expression)], Int)
        case tupleLit([Expression], Int)
        case ternary(Expression, Expression, Expression, Int)
        case nilCoalesce(Expression, Expression, Int)
        case range(Expression, Expression, Bool, Int)
        case closure([String], [Statement], Int)
        case forceUnwrap(Expression, Int)
        case optionalChain(Expression, String, Int)  // a?.b
    }

    indirect enum Statement {
        case expr(Expression)
        case varDecl(name: String, isConst: Bool, value: Expression?, line: Int)
        case ifStmt(cond: Expression, body: [Statement], else_: [Statement]?, line: Int)
        case ifLetStmt(name: String, value: Expression, body: [Statement], else_: [Statement]?, line: Int)
        case whileStmt(cond: Expression, body: [Statement], line: Int)
        case repeatStmt(body: [Statement], cond: Expression, line: Int)
        case forIn(varName: String, seq: Expression, body: [Statement], line: Int)
        case returnStmt(Expression?, Int)
        case break_(Int)
        case continue_(Int)
        case funcDecl(FunctionDecl)
        case guardLet(name: String, value: Expression, else_: [Statement], line: Int)
        case guardStmt(cond: Expression, else_: [Statement], line: Int)
        case switchStmt(value: Expression, cases: [SwitchCase], default_: [Statement]?, line: Int)
    }

    struct FunctionDecl {
        let name: String
        let params: [(label: String?, name: String, defaultVal: Expression?)]
        let body: [Statement]
        let line: Int
    }

    struct SwitchCase {
        let patterns: [Expression]      // literal values to match
        let body: [Statement]
    }

    // ────────────────────────────────────────────────────────────
    //          PARSER
    // ────────────────────────────────────────────────────────────

    final class Parser {
        private var tokens: [Token]
        private var pos = 0
        // When parsing inside an `if`/`while`/`guard`/`for-in` condition,
        // a `{` is the start of the loop/branch body — NOT a trailing
        // closure attached to the preceding call. We flip this flag off
        // around such headers so parsePostfix doesn't grab the body.
        private var allowTrailingClosures = true
        init(tokens: [Token]) { self.tokens = tokens }

        private var current: Token { tokens[pos] }
        private func peek(_ off: Int) -> Token { tokens[min(pos + off, tokens.count - 1)] }

        private func match(_ kinds: TokenKind...) -> Bool {
            for k in kinds {
                if current.kind == k { pos += 1; return true }
            }
            return false
        }

        private func matchKW(_ words: String...) -> Bool {
            if current.kind == .keyword, words.contains(current.lexeme) {
                pos += 1; return true
            }
            return false
        }

        private func check(_ k: TokenKind) -> Bool { current.kind == k }
        private func checkKW(_ w: String) -> Bool { current.kind == .keyword && current.lexeme == w }

        @discardableResult
        private func consume(_ k: TokenKind, _ msg: String) throws -> Token {
            if current.kind == k { let t = current; pos += 1; return t }
            throw RuntimeError(message: msg + " (got '\(current.lexeme)')", line: current.line)
        }

        // ───────── Program ─────────
        func parseProgram() throws -> [Statement] {
            var stmts: [Statement] = []
            while !check(.eof) {
                stmts.append(try parseStatement())
                _ = match(.semicolon)
            }
            return stmts
        }

        // ───────── Statements ─────────
        private func parseStatement() throws -> Statement {
            // `import Foundation` etc. — there are no modules to resolve
            // in the embedded interpreter, but real Swift code starts
            // with imports and silently ignoring them keeps copy-pasted
            // examples runnable. We consume the keyword + module path
            // (`Foundation`, `UIKit.UIView`, …) and emit an empty expr.
            if checkKW("import") {
                let line = current.line
                pos += 1
                if check(.ident) { pos += 1 }
                while match(.dot) {
                    if check(.ident) { pos += 1 }
                }
                return .expr(.nilLit(line))
            }
            // Access modifiers / declaration attributes — we just
            // skip them so e.g. `public func foo()` parses as if it
            // were `func foo()`. None of these affect runtime semantics
            // in the interpreter (everything is in one global scope).
            while current.kind == .keyword,
                  ["public", "private", "internal", "fileprivate",
                   "static", "override", "final"].contains(current.lexeme) {
                pos += 1
            }
            if checkKW("let") || checkKW("var") { return try parseVarDecl() }
            if checkKW("if") { return try parseIf() }
            if checkKW("while") { return try parseWhile() }
            if checkKW("repeat") { return try parseRepeat() }
            if checkKW("for") { return try parseForIn() }
            if checkKW("return") { return try parseReturn() }
            if checkKW("break") { let l = current.line; pos += 1; return .break_(l) }
            if checkKW("continue") { let l = current.line; pos += 1; return .continue_(l) }
            if checkKW("func") { return .funcDecl(try parseFuncDecl()) }
            if checkKW("guard") { return try parseGuard() }
            if checkKW("switch") { return try parseSwitch() }
            return .expr(try parseExpression())
        }

        private func parseVarDecl() throws -> Statement {
            let line = current.line
            let isConst = current.lexeme == "let"
            pos += 1
            let nameTok = try consume(.ident, "Expected variable name")
            // Optional type annotation : T — we ignore it (dynamic typing)
            if match(.colon) {
                _ = try parseTypeAnnotation()
            }
            var value: Expression? = nil
            if match(.eq) {
                value = try parseExpression()
            }
            return .varDecl(name: nameTok.lexeme, isConst: isConst,
                            value: value, line: line)
        }

        /// Skip over a type annotation. We don't type-check (dynamic
        /// semantics), but we need to consume the tokens so subsequent
        /// `=` parses correctly.
        private func parseTypeAnnotation() throws -> String {
            // The interpreter is dynamically typed — we throw the
            // annotation away — but we still have to *consume* it
            // cleanly so the parser ends up positioned right after.
            //
            // Types we tolerate: `Int`, `Double`, `String`, `Bool`,
            // `[Int]`, `[String: Int]`, `(Int, String)`, `Int?`,
            // `Int -> Int`, `[String]?`, etc. We follow bracket
            // depth so we stop at the matching `)` or `,` of the
            // *enclosing* parameter list — not the one nested
            // inside the type.
            var s = ""
            var depthParen = 0
            var depthBracket = 0
            while true {
                let k = current.kind
                if depthParen == 0 && depthBracket == 0 {
                    // Top-level terminators: `,`, `)`, `{`, `=`, `;`,
                    // and any statement keyword. Stop without consuming.
                    if k == .comma || k == .rparen || k == .lbrace
                        || k == .eq || k == .semicolon || k == .eof {
                        return s
                    }
                }
                switch k {
                case .ident, .keyword:
                    s += current.lexeme; pos += 1
                case .dot, .question, .bang, .arrow:
                    s += current.lexeme; pos += 1
                case .lparen:
                    depthParen += 1
                    s += current.lexeme; pos += 1
                case .rparen:
                    if depthParen == 0 { return s }
                    depthParen -= 1
                    s += current.lexeme; pos += 1
                case .lbracket:
                    depthBracket += 1
                    s += current.lexeme; pos += 1
                case .rbracket:
                    if depthBracket == 0 { return s }
                    depthBracket -= 1
                    s += current.lexeme; pos += 1
                case .colon, .comma:
                    // `:` and `,` are only meaningful *inside* `[K:V]`
                    // or `(A,B)`; at top level they end the annotation.
                    if depthParen == 0 && depthBracket == 0 { return s }
                    s += current.lexeme; pos += 1
                default:
                    return s
                }
            }
        }

        private func parseIf() throws -> Statement {
            let line = current.line
            pos += 1   // consume 'if'

            // `if let name = expr { ... }` form
            if checkKW("let") || checkKW("var") {
                pos += 1
                let nameTok = try consume(.ident, "Expected binding name after 'let'")
                try consume(.eq, "Expected '=' in if-let")
                let val = try parseHeaderExpression()
                let body = try parseBlock()
                var elseBlock: [Statement]? = nil
                if matchKW("else") {
                    if checkKW("if") { elseBlock = [try parseIf()] }
                    else { elseBlock = try parseBlock() }
                }
                return .ifLetStmt(name: nameTok.lexeme, value: val,
                                  body: body, else_: elseBlock, line: line)
            }

            let cond = try parseHeaderExpression()
            let body = try parseBlock()
            var elseBlock: [Statement]? = nil
            if matchKW("else") {
                if checkKW("if") { elseBlock = [try parseIf()] }
                else { elseBlock = try parseBlock() }
            }
            return .ifStmt(cond: cond, body: body, else_: elseBlock, line: line)
        }

        /// Parse an expression in a context where a following `{` opens
        /// a statement body, not a trailing closure (the cond of
        /// `if`/`while`/`guard`, the value in `if let`, the iterable
        /// in `for-in`, the subject of `switch`). Saves and restores
        /// the trailing-closure flag.
        private func parseHeaderExpression() throws -> Expression {
            let prev = allowTrailingClosures
            allowTrailingClosures = false
            defer { allowTrailingClosures = prev }
            return try parseExpression()
        }

        private func parseGuard() throws -> Statement {
            let line = current.line
            pos += 1   // consume 'guard'

            if checkKW("let") || checkKW("var") {
                pos += 1
                let nameTok = try consume(.ident, "Expected binding name after 'guard let'")
                try consume(.eq, "Expected '=' in guard-let")
                let val = try parseHeaderExpression()
                _ = matchKW("else")
                let body = try parseBlock()
                return .guardLet(name: nameTok.lexeme, value: val,
                                 else_: body, line: line)
            }
            let cond = try parseHeaderExpression()
            _ = matchKW("else")
            let body = try parseBlock()
            return .guardStmt(cond: cond, else_: body, line: line)
        }

        private func parseWhile() throws -> Statement {
            let line = current.line
            pos += 1
            let cond = try parseHeaderExpression()
            let body = try parseBlock()
            return .whileStmt(cond: cond, body: body, line: line)
        }

        private func parseRepeat() throws -> Statement {
            let line = current.line
            pos += 1
            let body = try parseBlock()
            guard matchKW("while") else {
                throw RuntimeError(message: "Expected 'while' after repeat block",
                                   line: current.line)
            }
            let cond = try parseExpression()
            return .repeatStmt(body: body, cond: cond, line: line)
        }

        private func parseForIn() throws -> Statement {
            let line = current.line
            pos += 1
            let nameTok = try consume(.ident, "Expected variable name in for-in")
            guard matchKW("in") else {
                throw RuntimeError(message: "Expected 'in' in for loop",
                                   line: current.line)
            }
            let seq = try parseHeaderExpression()
            let body = try parseBlock()
            return .forIn(varName: nameTok.lexeme, seq: seq, body: body, line: line)
        }

        private func parseReturn() throws -> Statement {
            let line = current.line
            pos += 1
            // No expression after return → return Void
            if check(.rbrace) || check(.eof) || check(.semicolon) {
                return .returnStmt(nil, line)
            }
            let e = try parseExpression()
            return .returnStmt(e, line)
        }

        private func parseFuncDecl() throws -> FunctionDecl {
            let line = current.line
            pos += 1   // consume 'func'
            let nameTok = try consume(.ident, "Expected function name")
            try consume(.lparen, "Expected '(' after function name")
            var params: [(label: String?, name: String, defaultVal: Expression?)] = []
            while !check(.rparen) {
                // Swift param shapes:
                //   name: Type                 ← internal name only
                //   label name: Type           ← external + internal
                //   _ name: Type               ← omit external label
                // The tokenizer emits `_` as an .ident (since `_` is a
                // valid identifier start), so we distinguish by checking
                // the lexeme — not the token kind — when looking for the
                // wildcard external label.
                var label: String? = nil
                var name = ""
                if current.kind == .ident && current.lexeme == "_" {
                    pos += 1
                    label = nil
                    name = try consume(.ident, "Expected param name after '_'").lexeme
                } else if current.kind == .ident {
                    let first = current.lexeme; pos += 1
                    if current.kind == .ident {
                        label = first
                        name = current.lexeme; pos += 1
                    } else {
                        name = first
                    }
                }
                if match(.colon) {
                    _ = try parseTypeAnnotation()
                }
                var defaultVal: Expression? = nil
                if match(.eq) {
                    defaultVal = try parseExpression()
                }
                params.append((label: label, name: name, defaultVal: defaultVal))
                if !match(.comma) { break }
            }
            try consume(.rparen, "Expected ')' after params")
            // Optional return type
            if match(.arrow) {
                _ = try parseTypeAnnotation()
            }
            let body = try parseBlock()
            return FunctionDecl(name: nameTok.lexeme, params: params,
                                body: body, line: line)
        }

        private func parseSwitch() throws -> Statement {
            let line = current.line
            pos += 1
            let val = try parseHeaderExpression()
            try consume(.lbrace, "Expected '{' to start switch body")
            var cases: [SwitchCase] = []
            var defaultBody: [Statement]? = nil
            while !check(.rbrace) {
                if matchKW("case") {
                    var patterns: [Expression] = []
                    patterns.append(try parseExpression())
                    while match(.comma) {
                        patterns.append(try parseExpression())
                    }
                    try consume(.colon, "Expected ':' after case patterns")
                    var body: [Statement] = []
                    while !checkKW("case") && !checkKW("default") && !check(.rbrace) {
                        body.append(try parseStatement())
                        _ = match(.semicolon)
                    }
                    cases.append(SwitchCase(patterns: patterns, body: body))
                } else if matchKW("default") {
                    try consume(.colon, "Expected ':' after default")
                    var body: [Statement] = []
                    while !check(.rbrace) {
                        body.append(try parseStatement())
                        _ = match(.semicolon)
                    }
                    defaultBody = body
                } else {
                    throw RuntimeError(message: "Expected 'case' or 'default' in switch",
                                       line: current.line)
                }
            }
            try consume(.rbrace, "Expected '}' to end switch")
            return .switchStmt(value: val, cases: cases,
                               default_: defaultBody, line: line)
        }

        private func parseBlock() throws -> [Statement] {
            try consume(.lbrace, "Expected '{'")
            var stmts: [Statement] = []
            while !check(.rbrace) && !check(.eof) {
                stmts.append(try parseStatement())
                _ = match(.semicolon)
            }
            try consume(.rbrace, "Expected '}'")
            return stmts
        }

        // ───────── Expressions (precedence climbing) ─────────

        private func parseExpression() throws -> Expression {
            return try parseAssignment()
        }

        private func parseAssignment() throws -> Expression {
            let line = current.line
            let lhs = try parseTernary()
            if check(.eq) || check(.plusEq) || check(.minusEq) || check(.starEq) || check(.slashEq) {
                let op = current.lexeme; pos += 1
                let rhs = try parseAssignment()
                return .assign(lhs, op, rhs, line)
            }
            return lhs
        }

        private func parseTernary() throws -> Expression {
            let line = current.line
            let cond = try parseLogicalOr()
            if match(.question) {
                let then = try parseExpression()
                try consume(.colon, "Expected ':' in ternary")
                let els = try parseExpression()
                return .ternary(cond, then, els, line)
            }
            return cond
        }

        private func parseLogicalOr() throws -> Expression {
            let line = current.line
            var left = try parseLogicalAnd()
            while match(.pipePipe) {
                let right = try parseLogicalAnd()
                left = .binary(left, "||", right, line)
            }
            return left
        }

        private func parseLogicalAnd() throws -> Expression {
            let line = current.line
            var left = try parseNilCoalesce()
            while match(.ampAmp) {
                let right = try parseNilCoalesce()
                left = .binary(left, "&&", right, line)
            }
            return left
        }

        private func parseNilCoalesce() throws -> Expression {
            let line = current.line
            let left = try parseEquality()
            if match(.questionQuestion) {
                let right = try parseEquality()
                return .nilCoalesce(left, right, line)
            }
            return left
        }

        private func parseEquality() throws -> Expression {
            let line = current.line
            var left = try parseComparison()
            while check(.eqEq) || check(.bangEq) {
                let op = current.lexeme; pos += 1
                let right = try parseComparison()
                left = .binary(left, op, right, line)
            }
            return left
        }

        private func parseComparison() throws -> Expression {
            let line = current.line
            var left = try parseRangeExpr()
            while check(.lt) || check(.gt) || check(.ltEq) || check(.gtEq) {
                let op = current.lexeme; pos += 1
                let right = try parseRangeExpr()
                left = .binary(left, op, right, line)
            }
            return left
        }

        private func parseRangeExpr() throws -> Expression {
            let line = current.line
            let left = try parseAddSub()
            if match(.dotDotLess) {
                let right = try parseAddSub()
                return .range(left, right, false, line)
            }
            if match(.dotDotDot) {
                let right = try parseAddSub()
                return .range(left, right, true, line)
            }
            return left
        }

        private func parseAddSub() throws -> Expression {
            let line = current.line
            var left = try parseMulDiv()
            while check(.plus) || check(.minus) {
                let op = current.lexeme; pos += 1
                let right = try parseMulDiv()
                left = .binary(left, op, right, line)
            }
            return left
        }

        private func parseMulDiv() throws -> Expression {
            let line = current.line
            var left = try parseUnary()
            while check(.star) || check(.slash) || check(.percent) {
                let op = current.lexeme; pos += 1
                let right = try parseUnary()
                left = .binary(left, op, right, line)
            }
            return left
        }

        private func parseUnary() throws -> Expression {
            let line = current.line
            if check(.minus) || check(.bang) {
                let op = current.lexeme; pos += 1
                let operand = try parseUnary()
                return .unary(op, operand, line)
            }
            return try parsePostfix()
        }

        private func parsePostfix() throws -> Expression {
            var expr = try parsePrimary()
            while true {
                let line = current.line
                if match(.dot) {
                    let memberTok = try consume(.ident, "Expected member name after '.'")
                    expr = .memberAccess(expr, memberTok.lexeme, line)
                } else if check(.question) && peek(1).kind == .dot {
                    pos += 2   // consume ?.
                    let memberTok = try consume(.ident, "Expected member after '?.'")
                    expr = .optionalChain(expr, memberTok.lexeme, line)
                } else if match(.lparen) {
                    let (args, labels) = try parseCallArgs()
                    expr = .call(expr, args, labels, line)
                } else if check(.lbracket) {
                    pos += 1
                    let idx = try parseExpression()
                    try consume(.rbracket, "Expected ']' after subscript")
                    expr = .subscriptAccess(expr, idx, line)
                } else if check(.bang) {
                    pos += 1
                    expr = .forceUnwrap(expr, line)
                } else if allowTrailingClosures && check(.lbrace) {
                    // Trailing closure. Suppressed inside if/while/guard/for
                    // condition headers — there the `{` opens the loop body.
                    let closure = try parseClosure()
                    if case .call(let fn, var args, var labels, let l) = expr {
                        args.append(closure)
                        labels.append(nil)
                        expr = .call(fn, args, labels, l)
                    } else {
                        expr = .call(expr, [closure], [nil], line)
                    }
                } else {
                    break
                }
            }
            return expr
        }

        private func parseCallArgs() throws -> ([Expression], [String?]) {
            var args: [Expression] = []
            var labels: [String?] = []
            while !check(.rparen) {
                // Look for `label:` prefix
                if current.kind == .ident && peek(1).kind == .colon {
                    let label = current.lexeme
                    pos += 2   // consume ident + colon
                    args.append(try parseExpression())
                    labels.append(label)
                } else {
                    args.append(try parseExpression())
                    labels.append(nil)
                }
                if !match(.comma) { break }
            }
            try consume(.rparen, "Expected ')' after arguments")
            return (args, labels)
        }

        private func parseClosure() throws -> Expression {
            let line = current.line
            try consume(.lbrace, "Expected '{' for closure")
            var params: [String] = []

            // Closure parameter forms we accept:
            //   { (a: T, b: T) -> R in body }   ← paren-wrapped, optionally typed, optional return
            //   { a, b in body }                 ← bare untyped
            //   { body }                         ← no params (use $0 / $1 shorthand)
            //
            // Strategy: scan ahead for `in` at brace-depth 0 to decide
            // whether there's a header. The previous "collect every
            // ident before `in`" approach mis-picked up type names
            // (`Int` in `(x: Int) -> Int in` looked like another param);
            // the state machine below tracks whether we're in a type
            // annotation or the return-arrow tail and only records the
            // first identifier of each comma-separated parameter chunk.
            let savedPos = pos
            var inPos = -1
            var braceDepth = 0
            for i in pos..<tokens.count {
                let t = tokens[i]
                if t.kind == .lbrace { braceDepth += 1 }
                else if t.kind == .rbrace {
                    if braceDepth == 0 { break }
                    braceDepth -= 1
                } else if braceDepth == 0,
                          t.kind == .keyword, t.lexeme == "in" {
                    inPos = i
                    break
                }
            }

            if inPos >= 0 {
                // Strip a wrapping `(…)` around the param list so depth
                // tracking treats commas at the same logical level.
                var startIdx = savedPos
                var endIdx = inPos
                if startIdx < endIdx, tokens[startIdx].kind == .lparen {
                    var d = 0
                    for i in startIdx..<endIdx {
                        if tokens[i].kind == .lparen { d += 1 }
                        else if tokens[i].kind == .rparen {
                            d -= 1
                            if d == 0 {
                                startIdx += 1
                                endIdx = i
                                break
                            }
                        }
                    }
                }
                var lookingForName = true
                var inType = false
                var depth = 0
                var i = startIdx
                while i < endIdx {
                    let t = tokens[i]
                    if t.kind == .lparen || t.kind == .lbracket {
                        depth += 1; i += 1; continue
                    }
                    if t.kind == .rparen || t.kind == .rbracket {
                        depth -= 1; i += 1; continue
                    }
                    if depth == 0 {
                        if t.kind == .arrow { break }            // -> ReturnType tail
                        if t.kind == .colon { inType = true; i += 1; continue }
                        if t.kind == .comma {
                            lookingForName = true
                            inType = false
                            i += 1; continue
                        }
                    }
                    if !inType, lookingForName,
                       t.kind == .ident, t.lexeme != "_" {
                        params.append(t.lexeme)
                        lookingForName = false
                    }
                    i += 1
                }
                pos = inPos + 1
            }

            var stmts: [Statement] = []
            while !check(.rbrace) && !check(.eof) {
                stmts.append(try parseStatement())
                _ = match(.semicolon)
            }
            try consume(.rbrace, "Expected '}' to close closure")
            return .closure(params, stmts, line)
        }

        private func parsePrimary() throws -> Expression {
            let line = current.line
            if check(.number) {
                let t = current; pos += 1
                switch t.literal! {
                case .int(let n): return .intLit(n, line)
                case .double(let d): return .doubleLit(d, line)
                default: break
                }
            }
            if check(.string) {
                let t = current; pos += 1
                if case .string(let s) = t.literal! { return .stringLit(s, line) }
            }
            if check(.stringInterpolation) {
                let t = current; pos += 1
                let pieces = (t.interpolationParts ?? []).map { piece -> (String, Expression?) in
                    let (text, exprSrc) = piece
                    if exprSrc.isEmpty { return (text, nil) }
                    // Parse the embedded expression
                    do {
                        let sub = try Tokenizer(source: exprSrc).tokenize()
                        let p = Parser(tokens: sub)
                        let e = try p.parseExpression()
                        return (text, e)
                    } catch {
                        return (text, nil)
                    }
                }
                return .interpolation(pieces, line)
            }
            if checkKW("true") { pos += 1; return .boolLit(true, line) }
            if checkKW("false") { pos += 1; return .boolLit(false, line) }
            if checkKW("nil") { pos += 1; return .nilLit(line) }
            if check(.ident) || checkKW("self") {
                let t = current; pos += 1
                return .identifier(t.lexeme, line)
            }
            if match(.lparen) {
                // Could be parenthesized expr, tuple, or empty tuple
                if match(.rparen) { return .tupleLit([], line) }
                let first = try parseExpression()
                if match(.comma) {
                    var elems = [first]
                    elems.append(try parseExpression())
                    while match(.comma) { elems.append(try parseExpression()) }
                    try consume(.rparen, "Expected ')'")
                    return .tupleLit(elems, line)
                }
                try consume(.rparen, "Expected ')'")
                return first
            }
            if match(.lbracket) {
                if match(.rbracket) { return .arrayLit([], line) }
                // Peek for dict-style `key: value`
                let savedPos = pos
                let firstKey = try parseExpression()
                if match(.colon) {
                    let firstVal = try parseExpression()
                    var entries: [(Expression, Expression)] = [(firstKey, firstVal)]
                    while match(.comma) {
                        let k = try parseExpression()
                        try consume(.colon, "Expected ':' in dict literal")
                        let v = try parseExpression()
                        entries.append((k, v))
                    }
                    try consume(.rbracket, "Expected ']' to close dict")
                    return .dictLit(entries, line)
                }
                // Else it was an array literal
                var elems = [firstKey]
                while match(.comma) {
                    elems.append(try parseExpression())
                }
                _ = savedPos
                try consume(.rbracket, "Expected ']' to close array")
                return .arrayLit(elems, line)
            }
            if check(.lbrace) { return try parseClosure() }
            throw RuntimeError(message: "Unexpected '\(current.lexeme)'", line: line)
        }
    }

    // ────────────────────────────────────────────────────────────
    //          EVALUATOR
    // ────────────────────────────────────────────────────────────

    /// Control-flow signals returned out-of-band by `execute`.
    enum FlowSignal {
        case proceed
        case returnValue(Value)
        case breakLoop
        case continueLoop
    }

    private func execute(_ stmt: Statement, env: Environment) throws -> FlowSignal {
        switch stmt {
        case .expr(let e):
            _ = try evaluate(e, env: env)
            return .proceed

        case .varDecl(let name, let isConst, let valueExpr, _):
            let v: Value = try valueExpr.map { try evaluate($0, env: env) } ?? .nil
            env.define(name, value: v, isConst: isConst)
            return .proceed

        case .ifStmt(let cond, let body, let elseBlock, _):
            let cv = try evaluate(cond, env: env)
            if isTruthy(cv) {
                return try executeBlock(body, parent: env)
            } else if let elseBlock = elseBlock {
                return try executeBlock(elseBlock, parent: env)
            }
            return .proceed

        case .ifLetStmt(let name, let valueExpr, let body, let elseBlock, _):
            let v = try evaluate(valueExpr, env: env)
            if case .nil = v {
                if let elseBlock = elseBlock {
                    return try executeBlock(elseBlock, parent: env)
                }
                return .proceed
            }
            let inner = Environment(parent: env)
            inner.define(name, value: v, isConst: true)
            return try runStmts(body, env: inner)

        case .whileStmt(let cond, let body, _):
            while isTruthy(try evaluate(cond, env: env)) {
                let r = try executeBlock(body, parent: env)
                if case .returnValue = r { return r }
                if case .breakLoop = r { break }
            }
            return .proceed

        case .repeatStmt(let body, let cond, _):
            repeat {
                let r = try executeBlock(body, parent: env)
                if case .returnValue = r { return r }
                if case .breakLoop = r { break }
            } while isTruthy(try evaluate(cond, env: env))
            return .proceed

        case .forIn(let varName, let seqExpr, let body, _):
            let seq = try evaluate(seqExpr, env: env)
            let values = try sequenceValues(seq, line: 0)
            for v in values {
                let inner = Environment(parent: env)
                inner.define(varName, value: v, isConst: true)
                let r = try runStmts(body, env: inner)
                if case .returnValue = r { return r }
                if case .breakLoop = r { break }
            }
            return .proceed

        case .returnStmt(let e, _):
            let v: Value = try e.map { try evaluate($0, env: env) } ?? .nil
            return .returnValue(v)

        case .break_:    return .breakLoop
        case .continue_: return .continueLoop

        case .funcDecl(let f):
            env.define(f.name, value: .function(f, env), isConst: true)
            return .proceed

        case .guardLet(let name, let valueExpr, let elseBlock, _):
            let v = try evaluate(valueExpr, env: env)
            if case .nil = v {
                let r = try executeBlock(elseBlock, parent: env)
                if case .returnValue = r { return r }
                if case .breakLoop = r { return r }
                return .proceed
            }
            env.define(name, value: v, isConst: true)
            return .proceed

        case .guardStmt(let cond, let elseBlock, _):
            let cv = try evaluate(cond, env: env)
            if !isTruthy(cv) {
                let r = try executeBlock(elseBlock, parent: env)
                if case .returnValue = r { return r }
                if case .breakLoop = r { return r }
            }
            return .proceed

        case .switchStmt(let valueExpr, let cases, let defaultBody, _):
            let v = try evaluate(valueExpr, env: env)
            for c in cases {
                for pat in c.patterns {
                    let pv = try evaluate(pat, env: env)
                    if valueEquals(v, pv) {
                        return try executeBlock(c.body, parent: env)
                    }
                }
            }
            if let db = defaultBody {
                return try executeBlock(db, parent: env)
            }
            return .proceed
        }
    }

    private func runStmts(_ stmts: [Statement], env: Environment) throws -> FlowSignal {
        for s in stmts {
            let r = try execute(s, env: env)
            if case .returnValue = r { return r }
            if case .breakLoop = r { return r }
            if case .continueLoop = r { return r }
        }
        return .proceed
    }

    private func executeBlock(_ stmts: [Statement], parent: Environment) throws -> FlowSignal {
        let inner = Environment(parent: parent)
        return try runStmts(stmts, env: inner)
    }

    // ───────── Expression evaluation ─────────

    private func evaluate(_ expr: Expression, env: Environment) throws -> Value {
        switch expr {
        case .intLit(let n, _):     return .int(n)
        case .doubleLit(let d, _):  return .double(d)
        case .stringLit(let s, _):  return .string(s)
        case .boolLit(let b, _):    return .bool(b)
        case .nilLit:               return .nil

        case .interpolation(let pieces, _):
            var out = ""
            for (text, e) in pieces {
                out += text
                if let e = e {
                    let v = try evaluate(e, env: env)
                    out += v.swiftDescription
                }
            }
            return .string(out)

        case .identifier(let name, let line):
            if let v = env.get(name) { return v }
            throw runtimeError("Unknown identifier '\(name)'", line: line)

        case .binary(let l, let op, let r, let line):
            let lv = try evaluate(l, env: env)
            // Short-circuit evaluation for && / ||
            if op == "&&" { return isTruthy(lv) ? try evaluate(r, env: env) : lv }
            if op == "||" { return isTruthy(lv) ? lv : try evaluate(r, env: env) }
            let rv = try evaluate(r, env: env)
            return try applyBinary(op, lv, rv, line: line)

        case .unary(let op, let e, let line):
            let v = try evaluate(e, env: env)
            return try applyUnary(op, v, line: line)

        case .assign(let target, let op, let rhs, let line):
            return try doAssignment(target: target, op: op, rhs: rhs,
                                    env: env, line: line)

        case .call(let fn, let args, let labels, let line):
            let callee = try evaluate(fn, env: env)
            var evArgs: [Value] = []
            for a in args { evArgs.append(try evaluate(a, env: env)) }
            return try callValue(callee, args: evArgs, labels: labels, line: line)

        case .memberAccess(let receiver, let member, let line):
            let r = try evaluate(receiver, env: env)
            return try resolveMember(of: r, name: member, line: line)

        case .optionalChain(let receiver, let member, let line):
            let r = try evaluate(receiver, env: env)
            if case .nil = r { return .nil }
            return try resolveMember(of: r, name: member, line: line)

        case .subscriptAccess(let receiver, let idx, let line):
            let r = try evaluate(receiver, env: env)
            let i = try evaluate(idx, env: env)
            return try doSubscript(receiver: r, index: i, line: line)

        case .arrayLit(let elems, _):
            var values: [Value] = []
            for e in elems { values.append(try evaluate(e, env: env)) }
            return .array(ArrayRef(values))

        case .dictLit(let entries, _):
            let d = DictRef()
            for (kE, vE) in entries {
                let k = try evaluate(kE, env: env)
                let v = try evaluate(vE, env: env)
                d.set(k, v)
            }
            return .dictionary(d)

        case .tupleLit(let elems, _):
            var vs: [Value] = []
            for e in elems { vs.append(try evaluate(e, env: env)) }
            return .tuple(vs)

        case .ternary(let cond, let then, let els, _):
            let cv = try evaluate(cond, env: env)
            return isTruthy(cv)
                ? try evaluate(then, env: env)
                : try evaluate(els, env: env)

        case .nilCoalesce(let l, let r, _):
            let lv = try evaluate(l, env: env)
            if case .nil = lv { return try evaluate(r, env: env) }
            return lv

        case .range(let l, let r, let closed, let line):
            let lv = try evaluate(l, env: env)
            let rv = try evaluate(r, env: env)
            guard case .int(let lo) = lv, case .int(let hi) = rv else {
                throw runtimeError("Range bounds must be Int", line: line)
            }
            return .range(lo, hi, closed)

        case .closure(let params, let body, _):
            // Closures become synthesized FunctionDecls.
            let fakeName = "__closure_\(UUID().uuidString.prefix(6))"
            let f = FunctionDecl(
                name: fakeName,
                params: params.map { ($0, $0, nil) },
                body: body,
                line: 0)
            return .function(f, env)

        case .forceUnwrap(let e, let line):
            let v = try evaluate(e, env: env)
            if case .nil = v {
                throw runtimeError("Force-unwrap of nil", line: line)
            }
            return v
        }
    }

    // MARK: Assignment

    private func doAssignment(target: Expression, op: String, rhs: Expression,
                              env: Environment, line: Int) throws -> Value {
        let newVal: Value
        if op == "=" {
            newVal = try evaluate(rhs, env: env)
        } else {
            let cur = try evaluate(target, env: env)
            let rv = try evaluate(rhs, env: env)
            let baseOp = String(op.dropLast())  // "+=" → "+"
            newVal = try applyBinary(baseOp, cur, rv, line: line)
        }
        switch target {
        case .identifier(let name, _):
            if !env.assign(name, value: newVal) {
                throw runtimeError("Cannot assign to undeclared variable '\(name)'",
                                   line: line)
            }
        case .subscriptAccess(let recvExpr, let idxExpr, _):
            let recv = try evaluate(recvExpr, env: env)
            let idx = try evaluate(idxExpr, env: env)
            try assignToSubscript(receiver: recv, index: idx, value: newVal, line: line)
        case .memberAccess:
            throw runtimeError("Assignment to member not supported (no struct/class)",
                               line: line)
        default:
            throw runtimeError("Invalid assignment target", line: line)
        }
        return newVal
    }

    private func assignToSubscript(receiver: Value, index: Value, value: Value,
                                    line: Int) throws {
        switch receiver {
        case .array(let a):
            guard case .int(let i) = index else {
                throw runtimeError("Array subscript must be Int", line: line)
            }
            guard i >= 0, i < a.values.count else {
                throw runtimeError("Array index \(i) out of range (size \(a.values.count))",
                                   line: line)
            }
            a.values[i] = value
        case .dictionary(let d):
            d.set(index, value)
        default:
            throw runtimeError("Type \(receiver.typeName) does not support subscript assignment",
                               line: line)
        }
    }

    // MARK: Operators

    private func applyBinary(_ op: String, _ a: Value, _ b: Value, line: Int) throws -> Value {
        // Numeric ops with auto-promotion
        if case .int(let x) = a, case .int(let y) = b {
            switch op {
            case "+": return .int(x + y)
            case "-": return .int(x - y)
            case "*": return .int(x * y)
            case "/":
                guard y != 0 else { throw runtimeError("Division by zero", line: line) }
                return .int(x / y)
            case "%":
                guard y != 0 else { throw runtimeError("Modulo by zero", line: line) }
                return .int(x % y)
            case "==": return .bool(x == y)
            case "!=": return .bool(x != y)
            case "<":  return .bool(x < y)
            case ">":  return .bool(x > y)
            case "<=": return .bool(x <= y)
            case ">=": return .bool(x >= y)
            default: break
            }
        }

        // Mixed Int+Double → Double
        if let (x, y) = numericPair(a, b) {
            switch op {
            case "+": return .double(x + y)
            case "-": return .double(x - y)
            case "*": return .double(x * y)
            case "/":
                guard y != 0 else { throw runtimeError("Division by zero", line: line) }
                return .double(x / y)
            case "==": return .bool(x == y)
            case "!=": return .bool(x != y)
            case "<":  return .bool(x < y)
            case ">":  return .bool(x > y)
            case "<=": return .bool(x <= y)
            case ">=": return .bool(x >= y)
            default: break
            }
        }

        // String concat / compare
        if case .string(let x) = a, case .string(let y) = b {
            switch op {
            case "+":  return .string(x + y)
            case "==": return .bool(x == y)
            case "!=": return .bool(x != y)
            case "<":  return .bool(x < y)
            case ">":  return .bool(x > y)
            case "<=": return .bool(x <= y)
            case ">=": return .bool(x >= y)
            default: break
            }
        }

        // Bool logic
        if case .bool(let x) = a, case .bool(let y) = b {
            switch op {
            case "==": return .bool(x == y)
            case "!=": return .bool(x != y)
            default: break
            }
        }

        // Nil equality
        if case .nil = a, case .nil = b {
            switch op {
            case "==": return .bool(true)
            case "!=": return .bool(false)
            default: break
            }
        }
        if case .nil = a {
            switch op {
            case "==": return .bool(false)
            case "!=": return .bool(true)
            default: break
            }
        }
        if case .nil = b {
            switch op {
            case "==": return .bool(false)
            case "!=": return .bool(true)
            default: break
            }
        }

        throw runtimeError("Cannot apply '\(op)' to \(a.typeName) and \(b.typeName)",
                           line: line)
    }

    private func numericPair(_ a: Value, _ b: Value) -> (Double, Double)? {
        func toDouble(_ v: Value) -> Double? {
            switch v {
            case .int(let n): return Double(n)
            case .double(let d): return d
            default: return nil
            }
        }
        if let x = toDouble(a), let y = toDouble(b),
           (a.typeName == "Double" || b.typeName == "Double") {
            return (x, y)
        }
        return nil
    }

    private func applyUnary(_ op: String, _ v: Value, line: Int) throws -> Value {
        switch op {
        case "-":
            if case .int(let n) = v { return .int(-n) }
            if case .double(let d) = v { return .double(-d) }
            throw runtimeError("Cannot negate \(v.typeName)", line: line)
        case "!":
            return .bool(!isTruthy(v))
        default:
            throw runtimeError("Unknown unary '\(op)'", line: line)
        }
    }

    // MARK: Truthiness + equality

    private func isTruthy(_ v: Value) -> Bool {
        switch v {
        case .bool(let b): return b
        case .nil: return false
        default: return true
        }
    }

    private func valueEquals(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)):       return x == y
        case (.double(let x), .double(let y)): return x == y
        case (.int(let x), .double(let y)):    return Double(x) == y
        case (.double(let x), .int(let y)):    return x == Double(y)
        case (.bool(let x), .bool(let y)):     return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.nil, .nil):                     return true
        default: return false
        }
    }

    // MARK: Sequences for for-in

    private func sequenceValues(_ v: Value, line: Int) throws -> [Value] {
        switch v {
        case .array(let a): return a.values
        case .range(let lo, let hi, let closed):
            let upper = closed ? hi : hi - 1
            if lo > upper { return [] }
            return (lo...upper).map { .int($0) }
        case .string(let s): return s.map { .string(String($0)) }
        default:
            throw runtimeError("Cannot iterate over \(v.typeName)", line: line)
        }
    }

    // MARK: Calls

    private func callValue(_ callee: Value, args: [Value], labels: [String?],
                           line: Int) throws -> Value {
        switch callee {
        case .builtin(let fn):
            return try fn(args)
        case .function(let decl, let capturedEnv):
            let inner = Environment(parent: capturedEnv)
            for (i, p) in decl.params.enumerated() {
                if i < args.count {
                    inner.define(p.name, value: args[i], isConst: true)
                } else if let dv = p.defaultVal {
                    inner.define(p.name, value: try evaluate(dv, env: capturedEnv),
                                 isConst: true)
                } else {
                    throw runtimeError("Missing argument for parameter '\(p.name)'",
                                       line: line)
                }
            }
            // Closure shorthand: $0, $1, $2 if no explicit params
            if decl.params.isEmpty && !args.isEmpty {
                for (i, v) in args.enumerated() {
                    inner.define("$\(i)", value: v, isConst: true)
                }
            }
            let r = try runStmts(decl.body, env: inner)
            if case .returnValue(let rv) = r { return rv }
            // Implicit return of last expression for single-expr closures
            if decl.body.count == 1, case .expr(let e) = decl.body[0] {
                return try evaluate(e, env: inner)
            }
            return .nil
        default:
            throw runtimeError("Cannot call \(callee.typeName)", line: line)
        }
    }

    // MARK: Member resolution + subscript

    private func resolveMember(of value: Value, name: String, line: Int) throws -> Value {
        switch value {
        case .array(let a):
            switch name {
            case "count":  return .int(a.values.count)
            case "isEmpty": return .bool(a.values.isEmpty)
            case "first":  return a.values.first ?? .nil
            case "last":   return a.values.last ?? .nil
            case "append": return .builtin { args in
                guard args.count == 1 else {
                    throw self.runtimeError("append takes 1 argument", line: line)
                }
                a.values.append(args[0])
                return .nil
            }
            case "removeLast": return .builtin { _ in
                guard !a.values.isEmpty else {
                    throw self.runtimeError("removeLast on empty array", line: line)
                }
                return a.values.removeLast()
            }
            case "removeFirst": return .builtin { _ in
                guard !a.values.isEmpty else {
                    throw self.runtimeError("removeFirst on empty array", line: line)
                }
                return a.values.removeFirst()
            }
            case "contains": return .builtin { args in
                guard args.count == 1 else {
                    throw self.runtimeError("contains takes 1 argument", line: line)
                }
                return .bool(a.values.contains(where: { self.valueEquals($0, args[0]) }))
            }
            case "reversed": return .builtin { _ in
                return .array(ArrayRef(Array(a.values.reversed())))
            }
            case "sorted": return .builtin { _ in
                let sorted = a.values.sorted { lhs, rhs in
                    switch (lhs, rhs) {
                    case (.int(let x), .int(let y)): return x < y
                    case (.double(let x), .double(let y)): return x < y
                    case (.string(let x), .string(let y)): return x < y
                    default: return false
                    }
                }
                return .array(ArrayRef(sorted))
            }
            case "map":    return makeHigherOrder(a, op: "map", line: line)
            case "filter": return makeHigherOrder(a, op: "filter", line: line)
            case "reduce": return makeHigherOrder(a, op: "reduce", line: line)
            default: break
            }
        case .string(let s):
            switch name {
            case "count":    return .int(s.count)
            case "isEmpty":  return .bool(s.isEmpty)
            case "uppercased": return .builtin { _ in .string(s.uppercased()) }
            case "lowercased": return .builtin { _ in .string(s.lowercased()) }
            case "reversed":   return .builtin { _ in .string(String(s.reversed())) }
            case "contains": return .builtin { args in
                guard args.count == 1, case .string(let sub) = args[0] else {
                    throw self.runtimeError("contains takes a String", line: line)
                }
                return .bool(s.contains(sub))
            }
            case "hasPrefix": return .builtin { args in
                guard args.count == 1, case .string(let p) = args[0] else {
                    throw self.runtimeError("hasPrefix takes a String", line: line)
                }
                return .bool(s.hasPrefix(p))
            }
            case "hasSuffix": return .builtin { args in
                guard args.count == 1, case .string(let p) = args[0] else {
                    throw self.runtimeError("hasSuffix takes a String", line: line)
                }
                return .bool(s.hasSuffix(p))
            }
            case "split": return .builtin { args in
                guard args.count == 1, case .string(let sep) = args[0] else {
                    throw self.runtimeError("split takes a separator String", line: line)
                }
                let parts = s.components(separatedBy: sep).map { Value.string($0) }
                return .array(ArrayRef(parts))
            }
            case "trimmed": return .builtin { _ in
                .string(s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            default: break
            }
        case .dictionary(let d):
            switch name {
            case "count":   return .int(d.entries.count)
            case "isEmpty": return .bool(d.entries.isEmpty)
            case "keys":    return .array(ArrayRef(d.entries.map { $0.0 }))
            case "values":  return .array(ArrayRef(d.entries.map { $0.1 }))
            default: break
            }
        case .int(let n):
            if name == "description" { return .string(String(n)) }
        case .double(let d):
            if name == "description" { return .string(String(d)) }
        default: break
        }
        throw runtimeError("\(value.typeName) has no member '\(name)'", line: line)
    }

    private func makeHigherOrder(_ a: ArrayRef, op: String, line: Int) -> Value {
        return .builtin { args in
            guard let fn = args.first else {
                throw self.runtimeError("\(op) takes a closure", line: line)
            }
            switch op {
            case "map":
                var out: [Value] = []
                for v in a.values {
                    let r = try self.callValue(fn, args: [v], labels: [nil], line: line)
                    out.append(r)
                }
                return .array(ArrayRef(out))
            case "filter":
                var out: [Value] = []
                for v in a.values {
                    let r = try self.callValue(fn, args: [v], labels: [nil], line: line)
                    if self.isTruthy(r) { out.append(v) }
                }
                return .array(ArrayRef(out))
            case "reduce":
                guard args.count >= 2 else {
                    throw self.runtimeError("reduce takes (initial, closure)", line: line)
                }
                var acc = args[0]
                let f = args[1]
                for v in a.values {
                    acc = try self.callValue(f, args: [acc, v], labels: [nil, nil],
                                              line: line)
                }
                return acc
            default:
                throw self.runtimeError("Unknown higher-order op", line: line)
            }
        }
    }

    private func doSubscript(receiver: Value, index: Value, line: Int) throws -> Value {
        switch receiver {
        case .array(let a):
            guard case .int(let i) = index else {
                throw runtimeError("Array subscript must be Int", line: line)
            }
            guard i >= 0, i < a.values.count else {
                throw runtimeError("Array index \(i) out of range (size \(a.values.count))",
                                   line: line)
            }
            return a.values[i]
        case .dictionary(let d):
            return d.get(index) ?? .nil
        case .string(let s):
            guard case .int(let i) = index else {
                throw runtimeError("String subscript must be Int", line: line)
            }
            guard i >= 0, i < s.count else {
                throw runtimeError("String index \(i) out of range", line: line)
            }
            let idx = s.index(s.startIndex, offsetBy: i)
            return .string(String(s[idx]))
        case .tuple(let xs):
            guard case .int(let i) = index else {
                throw runtimeError("Tuple subscript must be Int", line: line)
            }
            guard i >= 0, i < xs.count else {
                throw runtimeError("Tuple index \(i) out of range", line: line)
            }
            return xs[i]
        default:
            throw runtimeError("\(receiver.typeName) does not support subscript", line: line)
        }
    }

    // ────────────────────────────────────────────────────────────
    //          BUILT-INS
    // ────────────────────────────────────────────────────────────

    private func installBuiltins() {
        globalEnv.define("print", value: .builtin { [weak self] args in
            guard let self = self else { return .nil }
            let s = args.map { $0.swiftDescription }.joined(separator: " ")
            self.outputBuffer += s + "\n"
            return .nil
        }, isConst: true)

        globalEnv.define("Int", value: .builtin { args in
            guard let v = args.first else { return .nil }
            switch v {
            case .int(let n): return .int(n)
            case .double(let d): return .int(Int(d))
            case .string(let s): return Int(s).map { .int($0) } ?? .nil
            case .bool(let b): return .int(b ? 1 : 0)
            default: return .nil
            }
        }, isConst: true)

        globalEnv.define("Double", value: .builtin { args in
            guard let v = args.first else { return .nil }
            switch v {
            case .int(let n): return .double(Double(n))
            case .double(let d): return .double(d)
            case .string(let s): return Double(s).map { .double($0) } ?? .nil
            default: return .nil
            }
        }, isConst: true)

        globalEnv.define("String", value: .builtin { args in
            guard let v = args.first else { return .string("") }
            return .string(v.swiftDescription)
        }, isConst: true)

        globalEnv.define("Bool", value: .builtin { args in
            guard let v = args.first else { return .bool(false) }
            switch v {
            case .bool(let b): return .bool(b)
            case .string(let s): return .bool(s == "true")
            case .int(let n): return .bool(n != 0)
            default: return .bool(false)
            }
        }, isConst: true)

        globalEnv.define("abs", value: .builtin { args in
            guard let v = args.first else { return .nil }
            switch v {
            case .int(let n): return .int(Swift.abs(n))
            case .double(let d): return .double(Swift.abs(d))
            default: return .nil
            }
        }, isConst: true)

        globalEnv.define("min", value: .builtin { args in
            guard args.count >= 2 else { return .nil }
            var lowest = args[0]
            for v in args.dropFirst() {
                if case .int(let n) = v, case .int(let m) = lowest, n < m { lowest = v }
                if case .double(let n) = v, case .double(let m) = lowest, n < m { lowest = v }
            }
            return lowest
        }, isConst: true)

        globalEnv.define("max", value: .builtin { args in
            guard args.count >= 2 else { return .nil }
            var highest = args[0]
            for v in args.dropFirst() {
                if case .int(let n) = v, case .int(let m) = highest, n > m { highest = v }
                if case .double(let n) = v, case .double(let m) = highest, n > m { highest = v }
            }
            return highest
        }, isConst: true)

        globalEnv.define("sqrt", value: .builtin { args in
            guard let v = args.first else { return .nil }
            switch v {
            case .int(let n): return .double(Foundation.sqrt(Double(n)))
            case .double(let d): return .double(Foundation.sqrt(d))
            default: return .nil
            }
        }, isConst: true)

        globalEnv.define("pow", value: .builtin { args in
            guard args.count == 2 else { return .nil }
            func dv(_ v: Value) -> Double? {
                if case .int(let n) = v { return Double(n) }
                if case .double(let d) = v { return d }
                return nil
            }
            guard let b = dv(args[0]), let e = dv(args[1]) else { return .nil }
            return .double(Foundation.pow(b, e))
        }, isConst: true)
    }
}
