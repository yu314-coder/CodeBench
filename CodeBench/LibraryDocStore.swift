import Foundation

/// Loads per-library detailed markdown documentation from the app bundle.
///
/// The `.md` files live under `CodeBench/Resources/LibraryDocs/` in the
/// project tree; because the `CodeBench` group is a PBXFileSystemSynchronized-
/// RootGroup, Xcode copies them into the built product.
///
/// Lookup is case-insensitive and matches common aliases:
///   "NumPy"          → numpy.md
///   "Pillow"         → Pillow.md  (or pillow.md)
///   "scikit-learn"   → sklearn.md
///   "beautifulsoup4" → bs4.md
///   "manim (CE)"     → manim.md
///
/// Missing libraries simply return nil — the caller renders the hardcoded
/// summary + example from `LibraryModule` as before.
final class LibraryDocStore {

    static let shared = LibraryDocStore()

    private let cache = NSCache<NSString, NSString>()

    /// Common name → canonical doc file stem
    private let aliases: [String: String] = [
        // Pillow
        "pillow":         "Pillow",
        "pil":            "Pillow",
        // Numpy
        "numpy":          "numpy",
        "np":             "numpy",
        // Scipy
        "scipy":          "scipy",
        // sklearn
        "sklearn":        "sklearn",
        "scikit-learn":   "sklearn",
        "scikit_learn":   "sklearn",
        // matplotlib
        "matplotlib":     "matplotlib",
        "mpl":            "matplotlib",
        "pyplot":         "matplotlib",
        "plt":            "matplotlib",
        // plotly
        "plotly":         "plotly",
        // manim
        "manim":          "manim",
        "manim (ce)":     "manim",
        "manim_community_edition": "manim",
        // psutil
        "psutil":         "psutil",
        // torch
        "torch":          "torch",
        "pytorch":        "torch",
        // transformers
        "transformers":   "transformers",
        "huggingface_hub": "huggingface_hub",
        "huggingface_hub_": "huggingface_hub",
        // rich
        "rich":           "rich",
        // requests / bs4
        "requests":       "requests",
        "beautifulsoup":  "bs4",
        "beautifulsoup4": "bs4",
        "bs4":            "bs4",
        // av
        "av":             "av",
        "pyav":           "av",
        // networkx
        "networkx":       "networkx",
        "nx":             "networkx",
        // sympy
        "sympy":          "sympy",
        // pygments
        "pygments":       "pygments",
        // cairo
        "cairo":          "cairo",
        "pycairo":        "cairo",
        // tqdm
        "tqdm":           "tqdm",
    ]

    private init() {}

    /// Whether a given library has a detailed .md guide shipped.
    func hasMarkdown(for libraryName: String) -> Bool {
        return markdown(for: libraryName) != nil
    }

    /// Raw markdown contents including YAML front-matter (caller strips if needed).
    /// Returns nil when no matching file exists.
    func markdown(for libraryName: String) -> String? {
        let stem = resolveStem(for: libraryName)
        let key = stem as NSString
        if let cached = cache.object(forKey: key) { return cached as String }

        // Try a handful of possible locations in the bundle
        let candidates: [URL?] = [
            Bundle.main.url(forResource: stem, withExtension: "md"),
            Bundle.main.url(forResource: stem, withExtension: "md", subdirectory: "LibraryDocs"),
            Bundle.main.url(forResource: stem, withExtension: "md", subdirectory: "Resources/LibraryDocs"),
            Bundle.main.url(forResource: stem.lowercased(), withExtension: "md"),
            Bundle.main.url(forResource: stem.lowercased(), withExtension: "md", subdirectory: "LibraryDocs"),
        ]
        for url in candidates {
            if let url = url, let text = try? String(contentsOf: url, encoding: .utf8) {
                cache.setObject(text as NSString, forKey: key)
                return text
            }
        }
        return nil
    }

    /// Case-insensitive alias resolution → canonical stem. Falls through to
    /// a cleaned version of the input if no alias matches.
    private func resolveStem(for name: String) -> String {
        let normalised = name
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return aliases[normalised] ?? normalised
    }
}
