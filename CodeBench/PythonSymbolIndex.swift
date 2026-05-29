import Foundation

/// Introspects installed Python libraries and builds a symbol index for autocomplete.
/// On first launch, runs a Python script that imports each supported library and calls `dir()`
/// to get its public members. Results are cached to disk.
final class PythonSymbolIndex {

    static let shared = PythonSymbolIndex()

    /// `moduleName → [public symbol names]` (e.g. "numpy" → ["array", "zeros", "ones", ...])
    private(set) var moduleMembers: [String: [String]] = [:]

    /// `moduleName → [(name, kind)]` — kind-annotated members (v3)
    private(set) var moduleKinds: [String: [String: CompletionKind]] = [:]

    /// Modules available in the environment (top-level names)
    private(set) var availableModules: Set<String> = []

    private var isBuilt = false
    private let cacheKey = "python.symbol.index.v4"
    private let queue = DispatchQueue(label: "codebench.python.symindex", qos: .utility)

    /// Modules whose members are being / have been fetched lazily, so we
    /// don't re-request the same module on every keystroke.
    private var fetchingMembers: Set<String> = []
    private var triedMembers: Set<String> = []

    private init() {
        loadFromCache()
    }

    /// Libraries whose members we introspect *eagerly* at build time, so
    /// the most common `module.` completions are instant. Every other
    /// importable module still appears in the name list (full discovery
    /// below) and gets its members fetched lazily on first `.` access.
    private let knownModules: [String] = [
        "numpy", "scipy", "sklearn", "matplotlib.pyplot", "matplotlib",
        "sympy", "mpmath", "plotly", "networkx",
        "PIL", "av", "cairo",
        "manim", "manimpango",
        "requests", "httpx", "bs4",  // BeautifulSoup
        "pandas", "openpyxl", "webview", "flask",
        "json", "os", "sys", "math", "random", "time", "datetime",
        "re", "collections", "itertools", "functools",
        "pathlib", "typing", "dataclasses", "io", "csv", "sqlite3",
        "string", "textwrap", "hashlib", "base64", "pickle",
        "tqdm", "rich", "click", "pygments", "yaml",
        "jsonschema", "pydub", "svgelements", "offlinai_latex",
    ]

    /// Default (common) aliases users type — used for auto-alias resolution.
    let defaultAliases: [String: String] = [
        "np": "numpy",
        "plt": "matplotlib.pyplot",
        "pd": "pandas",  // not shipped, but users try it
        "nx": "networkx",
        "sp": "scipy",
        "sym": "sympy",
        "mpl": "matplotlib",
    ]

    // MARK: - Build

    /// Build (or rebuild) the symbol index. Runs in the background.
    func buildIfNeeded(completion: (() -> Void)? = nil) {
        guard !isBuilt else { completion?(); return }
        queue.async { [weak self] in
            self?.build()
            DispatchQueue.main.async { completion?() }
        }
    }

    private func build() {
        // Python script that introspects each module and classifies each member.
        // Returns `[name, kind]` per symbol so we can assign icons in the UI.
        let eagerList = knownModules.map { "\"\($0)\"" }.joined(separator: ", ")
        let script = """
        import sys, os, json, inspect
        result = {"members": {}, "modules": []}
        try:
            import importlib

            # Kind codes must match Swift's `CompletionKind` raw values (LSP spec).
            def classify(obj):
                try:
                    if inspect.ismodule(obj): return 9       # module
                    if inspect.isclass(obj): return 7        # class
                    if inspect.ismethod(obj): return 2       # method
                    if inspect.isfunction(obj) or inspect.isbuiltin(obj): return 3  # function
                    if isinstance(obj, type): return 7       # class
                    if isinstance(obj, (int, float, complex, bool, bytes)): return 21  # constant
                    if isinstance(obj, str): return 21       # constant (string)
                    if isinstance(obj, (list, tuple, set, frozenset, dict)): return 6  # collection
                    if callable(obj): return 3               # function fallback
                    return 6                                 # variable
                except Exception:
                    return 6

            # ── 1. eager member introspection for the common libraries ──
            members = {}
            for name in [\(eagerList)]:
                try:
                    mod = importlib.import_module(name)
                    items = {}
                    count = 0
                    for m in dir(mod):
                        if m.startswith('_'): continue
                        if count >= 400: break
                        try:
                            items[m] = classify(getattr(mod, m))
                        except Exception:
                            items[m] = 6
                        count += 1
                    members[name] = items
                except Exception:
                    pass
            result["members"] = members

            # ── 2. discover EVERY importable top-level module name ──
            #     (names only, no import — cheap, so the list is complete:
            #      stdlib + builtins + everything in every site-packages)
            mods = set()
            try: mods |= set(sys.builtin_module_names)
            except Exception: pass
            try: mods |= set(sys.stdlib_module_names)
            except Exception: pass
            SKIP = ('.dist-info', '.egg-info', '.txt', '.cfg', '.pth', '.md', '.json')
            for p in list(sys.path):
                if not p or not os.path.isdir(p): continue
                try: entries = os.listdir(p)
                except OSError: continue
                for e in entries:
                    if e.startswith(('_', '.')): continue
                    if e.endswith(SKIP): continue
                    full = os.path.join(p, e)
                    try:
                        if os.path.isdir(full):
                            if (os.path.exists(os.path.join(full, '__init__.py')) or
                                os.path.exists(os.path.join(full, '__init__.pyc'))):
                                mods.add(e)
                        elif e.endswith(('.py', '.pyc')):
                            base = e.split('.', 1)[0]
                            if base[:1].isalpha(): mods.add(base)
                        elif e.endswith('.so') or '.cpython' in e or '.abi3' in e:
                            base = e.split('.', 1)[0]
                            if base[:1].isalpha(): mods.add(base)
                    except OSError:
                        pass
            result["modules"] = sorted(m for m in mods if m and not m.startswith('_'))

            print("__SYMIDX_START__")
            print(json.dumps(result))
            print("__SYMIDX_END__")
        except Exception as _e:
            print("__SYMIDX_ERROR__", _e)
        """

        let result = PythonRuntime.shared.execute(code: script)
        let output = result.output

        guard let startRange = output.range(of: "__SYMIDX_START__"),
              let endRange = output.range(of: "__SYMIDX_END__") else {
            print("[symindex] No markers found in output")
            return
        }

        let jsonPart = output[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonPart.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("[symindex] Failed to parse JSON")
            return
        }

        let parsedMembers = (root["members"] as? [String: [String: Int]]) ?? [:]
        let discovered = (root["modules"] as? [String]) ?? []

        var members: [String: [String]] = [:]
        var kinds: [String: [String: CompletionKind]] = [:]
        // Seed the importable-name set from the full discovery, then add
        // any eagerly-indexed modules (+ their top-level package names).
        var available: Set<String> = Set(discovered)
        for (mod, symMap) in parsedMembers {
            members[mod] = Array(symMap.keys).sorted()
            var kindMap: [String: CompletionKind] = [:]
            for (name, rawKind) in symMap {
                kindMap[name] = CompletionKind(rawValue: rawKind) ?? .variable
            }
            kinds[mod] = kindMap
            available.insert(mod)
            if let dotIdx = mod.firstIndex(of: ".") {
                available.insert(String(mod[..<dotIdx]))
            }
        }

        moduleMembers = members
        moduleKinds = kinds
        availableModules = available
        isBuilt = true
        saveToCache()
        print("[symindex] Indexed \(members.count) modules w/ members, "
              + "\(available.count) importable names (v4)")
    }

    // MARK: - Cache

    private var cacheURL: URL? {
        guard let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return docs.appendingPathComponent(".symbol_index.json")
    }

    private func saveToCache() {
        guard let url = cacheURL else { return }
        // Serialize kinds as `[module: [name: rawValue]]`
        var kindsSerialized: [String: [String: Int]] = [:]
        for (mod, map) in moduleKinds {
            var m: [String: Int] = [:]
            for (n, k) in map { m[n] = k.rawValue }
            kindsSerialized[mod] = m
        }
        let payload: [String: Any] = [
            "version": cacheKey,
            "modules": moduleMembers,
            "kinds": kindsSerialized,
            "available": Array(availableModules),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: url)
        }
    }

    private func loadFromCache() {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        // Only accept v3 cache (older v2 lacks kind info)
        if (payload["version"] as? String) != cacheKey { return }
        if let mods = payload["modules"] as? [String: [String]] {
            moduleMembers = mods
            isBuilt = true
        }
        if let kindsRaw = payload["kinds"] as? [String: [String: Int]] {
            var out: [String: [String: CompletionKind]] = [:]
            for (mod, map) in kindsRaw {
                var m: [String: CompletionKind] = [:]
                for (name, raw) in map { m[name] = CompletionKind(rawValue: raw) ?? .variable }
                out[mod] = m
            }
            moduleKinds = out
        }
        if let avail = payload["available"] as? [String] {
            availableModules = Set(avail)
        }
    }

    // MARK: - Query

    /// Get member names for a module (real name or via alias).
    func members(of moduleOrAlias: String, aliases: [String: String] = [:]) -> [String] {
        let resolved = aliases[moduleOrAlias] ?? defaultAliases[moduleOrAlias] ?? moduleOrAlias
        return moduleMembers[resolved] ?? []
    }

    /// Resolve alias → real module name (for `module` field on CompletionItem).
    func resolveAlias(_ moduleOrAlias: String, aliases: [String: String] = [:]) -> String {
        return aliases[moduleOrAlias] ?? defaultAliases[moduleOrAlias] ?? moduleOrAlias
    }

    /// Get the kind for a single symbol within a module (real name).
    func kind(of symbol: String, in module: String) -> CompletionKind {
        return moduleKinds[module]?[symbol] ?? .variable
    }

    /// Get member (name, kind) pairs for a module or alias.
    func membersWithKinds(of moduleOrAlias: String, aliases: [String: String] = [:]) -> [(name: String, kind: CompletionKind)] {
        let resolved = resolveAlias(moduleOrAlias, aliases: aliases)
        guard let kindMap = moduleKinds[resolved], !kindMap.isEmpty else {
            // Fallback to members-only list with default kind
            return (moduleMembers[resolved] ?? []).map { (name: $0, kind: CompletionKind.variable) }
        }
        return kindMap.map { (name: $0.key, kind: $0.value) }
    }

    /// Check if a module (or alias) is indexed.
    func isKnown(_ moduleOrAlias: String, aliases: [String: String] = [:]) -> Bool {
        let resolved = aliases[moduleOrAlias] ?? defaultAliases[moduleOrAlias] ?? moduleOrAlias
        return moduleMembers[resolved] != nil
    }

    /// All importable module names (for `import x` / bare suggestions).
    /// Returns the full discovered universe (stdlib + builtins + every
    /// site-packages top-level), not just the eagerly-introspected libs.
    var allModules: [String] {
        availableModules.isEmpty ? Array(moduleMembers.keys).sorted()
                                 : availableModules.sorted()
    }

    /// Fetch a module's members on demand, for any importable module that
    /// wasn't eagerly indexed (e.g. `webview`, `torch`, a stdlib module).
    /// Introspects `dir()` live via the IntelliSense daemon, caches the
    /// result, and calls `completion(true)` — on the main queue — only
    /// when new members were added, so the caller can refresh its list.
    /// Dedups in-flight and already-tried modules so it's safe to call on
    /// every keystroke.
    func ensureMembers(of resolvedModule: String, completion: @escaping (Bool) -> Void) {
        if let existing = moduleKinds[resolvedModule], !existing.isEmpty {
            completion(false); return
        }
        let top = resolvedModule.components(separatedBy: ".").first ?? resolvedModule
        guard availableModules.contains(resolvedModule) || availableModules.contains(top) else {
            completion(false); return   // not importable — nothing to fetch
        }
        guard !fetchingMembers.contains(resolvedModule),
              !triedMembers.contains(resolvedModule) else { completion(false); return }
        fetchingMembers.insert(resolvedModule)
        IntelliSenseEngine.shared.listMembers(of: resolvedModule) { [weak self] pairs, answered in
            guard let self = self else { return }
            self.fetchingMembers.remove(resolvedModule)
            // Only give up permanently if the daemon actually answered (even
            // empty — e.g. a module that can't import). A timeout stays
            // retryable: the import may simply be slow the first time and
            // will be cached for the next access.
            if answered { self.triedMembers.insert(resolvedModule) }
            guard !pairs.isEmpty else { completion(false); return }
            var kindMap: [String: CompletionKind] = [:]
            for (name, kind) in pairs { kindMap[name] = kind }
            self.moduleKinds[resolvedModule] = kindMap
            self.moduleMembers[resolvedModule] = pairs.map { $0.0 }.sorted()
            self.saveToCache()
            completion(true)
        }
    }
}

// MARK: - Import Parser

/// Parses `import` and `from X import Y` statements in Python source to build an alias map.
/// Returns:
///   - aliases: `alias → moduleName` (e.g. `np → numpy`)
///   - wildcardImports: modules imported via `from X import *` (symbols are available bare)
///   - fromImports: `symbolName → moduleName` from `from X import foo, bar`
struct PythonImportScanner {

    struct ParsedImports {
        var aliases: [String: String] = [:]
        var wildcardImports: [String] = []
        var fromImports: [String: String] = [:]
    }

    static func scan(_ code: String) -> ParsedImports {
        var result = ParsedImports()

        let lines = code.components(separatedBy: "\n")
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Case 1: `from X import *`
            if let m = line.range(of: #"^from\s+([\w\.]+)\s+import\s+\*"#, options: .regularExpression) {
                let captured = String(line[m])
                if let modMatch = captured.range(of: #"(?<=from\s)([\w\.]+)"#, options: .regularExpression) {
                    let mod = String(captured[modMatch])
                    result.wildcardImports.append(mod)
                }
                continue
            }

            // Case 2: `from X import a, b as c`
            if line.hasPrefix("from ") && line.contains(" import ") {
                let parts = line.components(separatedBy: " import ")
                guard parts.count == 2 else { continue }
                let moduleName = parts[0].replacingOccurrences(of: "from ", with: "").trimmingCharacters(in: .whitespaces)
                let items = parts[1].components(separatedBy: ",")
                for item in items {
                    let trimmed = item.trimmingCharacters(in: .whitespaces)
                    if trimmed.contains(" as ") {
                        let pair = trimmed.components(separatedBy: " as ")
                        if pair.count == 2 {
                            let alias = pair[1].trimmingCharacters(in: .whitespaces)
                            result.fromImports[alias] = moduleName
                        }
                    } else {
                        result.fromImports[trimmed] = moduleName
                    }
                }
                continue
            }

            // Case 3: `import X` or `import X as Y` or `import X.Y as Z`
            if line.hasPrefix("import ") {
                let rest = line.replacingOccurrences(of: "import ", with: "")
                for item in rest.components(separatedBy: ",") {
                    let trimmed = item.trimmingCharacters(in: .whitespaces)
                    if trimmed.contains(" as ") {
                        let pair = trimmed.components(separatedBy: " as ")
                        if pair.count == 2 {
                            let modName = pair[0].trimmingCharacters(in: .whitespaces)
                            let alias = pair[1].trimmingCharacters(in: .whitespaces)
                            result.aliases[alias] = modName
                        }
                    } else {
                        // `import numpy` → alias == module name (use as-is)
                        let modName = trimmed
                        // Only register the last segment as the alias (i.e. `matplotlib.pyplot` isn't typed bare)
                        if let last = modName.components(separatedBy: ".").last {
                            result.aliases[last] = modName
                        }
                    }
                }
            }
        }

        return result
    }
}
