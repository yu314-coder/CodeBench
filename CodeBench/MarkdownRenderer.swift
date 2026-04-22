import UIKit

// MARK: - Markdown Renderer

enum MarkdownRenderer {

    /// Parsed code block for copy support
    struct CodeBlock {
        let language: String
        let code: String
        let range: NSRange
    }

    /// Render result containing attributed string and extracted code blocks
    struct RenderResult {
        let attributedString: NSAttributedString
        let codeBlocks: [CodeBlock]
    }

    // MARK: - Public API

    static func render(
        _ markdown: String,
        font: UIFont = .systemFont(ofSize: 15),
        textColor: UIColor = .label,
        isDark: Bool = ThemeManager.shared.isDark
    ) -> NSAttributedString {
        return renderFull(markdown, font: font, textColor: textColor, isDark: isDark).attributedString
    }

    static func renderFull(
        _ markdown: String,
        font: UIFont = .systemFont(ofSize: 15),
        textColor: UIColor = .label,
        isDark: Bool = ThemeManager.shared.isDark
    ) -> RenderResult {
        let result = NSMutableAttributedString()
        var codeBlocks: [CodeBlock] = []

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockLang = ""
        var codeBlockLines: [String] = []
        var needsNewline = false

        for line in lines {
            // ── Code block fences ──
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                if inCodeBlock {
                    let codeText = codeBlockLines.joined(separator: "\n")
                    if needsNewline { result.append(newline(baseAttrs)) }
                    let blockStart = result.length
                    result.append(renderCodeBlock(codeText, language: codeBlockLang, isDark: isDark))
                    let blockRange = NSRange(location: blockStart, length: result.length - blockStart)
                    codeBlocks.append(CodeBlock(language: codeBlockLang, code: codeText, range: blockRange))
                    codeBlockLines.removeAll()
                    inCodeBlock = false
                    codeBlockLang = ""
                    needsNewline = true
                } else {
                    inCodeBlock = true
                    codeBlockLang = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCodeBlock {
                codeBlockLines.append(line)
                continue
            }

            // ── Newline between lines ──
            if needsNewline {
                result.append(newline(baseAttrs))
            }
            needsNewline = true

            // ── Blank line ──
            if trimmedLine.isEmpty {
                needsNewline = false
                result.append(newline(baseAttrs))
                continue
            }

            // ── Horizontal rule ──
            if trimmedLine.count >= 3 && (trimmedLine.allSatisfy({ $0 == "-" }) || trimmedLine.allSatisfy({ $0 == "*" }) || trimmedLine.allSatisfy({ $0 == "_" })) {
                let ruleAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.separator]
                result.append(NSAttributedString(string: String(repeating: "\u{2500}", count: 30), attributes: ruleAttrs))
                continue
            }

            // ── Headings ──
            if let heading = parseHeading(line) {
                let sizes: [Int: CGFloat] = [1: 24, 2: 20, 3: 17, 4: 15]
                let size = sizes[heading.level] ?? font.pointSize
                let hStyle = NSMutableParagraphStyle()
                hStyle.lineSpacing = 4
                hStyle.paragraphSpacingBefore = 6
                let hAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: size, weight: .bold),
                    .foregroundColor: textColor,
                    .paragraphStyle: hStyle
                ]
                result.append(renderInline(heading.text, baseAttrs: hAttrs, isDark: isDark))
                continue
            }

            // ── Blockquote ──
            if trimmedLine.hasPrefix(">") {
                let quoteText = String(trimmedLine.drop(while: { $0 == ">" || $0 == " " }))
                let quoteStyle = NSMutableParagraphStyle()
                quoteStyle.firstLineHeadIndent = 12
                quoteStyle.headIndent = 12
                let quoteAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.italicSystemFont(ofSize: font.pointSize),
                    .foregroundColor: textColor.withAlphaComponent(0.7),
                    .paragraphStyle: quoteStyle
                ]
                let bar = NSAttributedString(string: "┃ ", attributes: [.font: font, .foregroundColor: WorkspaceStyle.accent])
                result.append(bar)
                result.append(renderInline(quoteText, baseAttrs: quoteAttrs, isDark: isDark))
                continue
            }

            // ── Unordered list ──
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                let indent = leadingSpaceCount(line)
                let content = String(line.drop(while: { $0 == " " || $0 == "\t" }).dropFirst(2))
                let bulletStyle = NSMutableParagraphStyle()
                bulletStyle.firstLineHeadIndent = CGFloat(indent / 2) * 12 + 8
                bulletStyle.headIndent = CGFloat(indent / 2) * 12 + 20
                bulletStyle.lineSpacing = 2
                var bulletAttrs = baseAttrs
                bulletAttrs[.paragraphStyle] = bulletStyle
                result.append(NSAttributedString(string: "  • ", attributes: bulletAttrs))
                result.append(renderInline(content, baseAttrs: bulletAttrs, isDark: isDark))
                continue
            }

            // ── Ordered list ──
            if let (num, content) = parseOrderedList(trimmedLine) {
                let olStyle = NSMutableParagraphStyle()
                olStyle.firstLineHeadIndent = 8
                olStyle.headIndent = 24
                olStyle.lineSpacing = 2
                var olAttrs = baseAttrs
                olAttrs[.paragraphStyle] = olStyle
                result.append(NSAttributedString(string: "  \(num). ", attributes: olAttrs))
                result.append(renderInline(content, baseAttrs: olAttrs, isDark: isDark))
                continue
            }

            // ── Regular paragraph ──
            result.append(renderInline(line, baseAttrs: baseAttrs, isDark: isDark))
        }

        // Handle unclosed code block (streaming)
        if inCodeBlock && !codeBlockLines.isEmpty {
            let codeText = codeBlockLines.joined(separator: "\n")
            if needsNewline { result.append(newline(baseAttrs)) }
            let blockStart = result.length
            result.append(renderCodeBlock(codeText, language: codeBlockLang, isDark: isDark))
            codeBlocks.append(CodeBlock(language: codeBlockLang, code: codeText, range: NSRange(location: blockStart, length: result.length - blockStart)))
        }

        return RenderResult(attributedString: result, codeBlocks: codeBlocks)
    }

    // MARK: - Inline rendering

    private static func renderInline(_ text: String, baseAttrs: [NSAttributedString.Key: Any], isDark: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            // Bold+Italic ***text***
            if i + 2 < chars.count && chars[i] == "*" && chars[i+1] == "*" && chars[i+2] == "*" {
                if let end = findClosing("***", in: chars, from: i + 3) {
                    let content = String(chars[(i+3)..<end])
                    var attrs = baseAttrs
                    if let f = attrs[.font] as? UIFont {
                        attrs[.font] = f.bold().italic()
                    }
                    result.append(NSAttributedString(string: content, attributes: attrs))
                    i = end + 3
                    continue
                }
            }

            // Bold **text**
            if i + 1 < chars.count && chars[i] == "*" && chars[i+1] == "*" {
                if let end = findClosing("**", in: chars, from: i + 2) {
                    let content = String(chars[(i+2)..<end])
                    var attrs = baseAttrs
                    if let f = attrs[.font] as? UIFont { attrs[.font] = f.bold() }
                    result.append(NSAttributedString(string: content, attributes: attrs))
                    i = end + 2
                    continue
                }
            }

            // Italic *text* (not **)
            if chars[i] == "*" && (i + 1 >= chars.count || chars[i+1] != "*") {
                if let end = findClosingSingle("*", in: chars, from: i + 1) {
                    let content = String(chars[(i+1)..<end])
                    var attrs = baseAttrs
                    if let f = attrs[.font] as? UIFont { attrs[.font] = f.italic() }
                    result.append(NSAttributedString(string: content, attributes: attrs))
                    i = end + 1
                    continue
                }
            }

            // Inline code `text`
            if chars[i] == "`" && (i + 1 >= chars.count || chars[i+1] != "`") {
                if let end = findClosingSingle("`", in: chars, from: i + 1) {
                    let content = String(chars[(i+1)..<end])
                    let codeFont = UIFont(name: "Menlo", size: ((baseAttrs[.font] as? UIFont)?.pointSize ?? 15) - 1) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
                    let codeBg = isDark ? UIColor(white: 1.0, alpha: 0.10) : UIColor(white: 0.0, alpha: 0.06)
                    let codeFg = isDark ? UIColor(red: 0.55, green: 0.85, blue: 0.65, alpha: 1) : UIColor(red: 0.78, green: 0.18, blue: 0.28, alpha: 1)
                    let codeAttrs: [NSAttributedString.Key: Any] = [
                        .font: codeFont,
                        .foregroundColor: codeFg,
                        .backgroundColor: codeBg
                    ]
                    result.append(NSAttributedString(string: "\u{00A0}\(content)\u{00A0}", attributes: codeAttrs))
                    i = end + 1
                    continue
                }
            }

            // Link [text](url)
            if chars[i] == "[" {
                if let (linkText, url, endIdx) = parseLink(chars, from: i) {
                    var attrs = baseAttrs
                    attrs[.foregroundColor] = WorkspaceStyle.accent
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    if let u = URL(string: url) { attrs[.link] = u }
                    result.append(NSAttributedString(string: linkText, attributes: attrs))
                    i = endIdx
                    continue
                }
            }

            // Plain character
            result.append(NSAttributedString(string: String(chars[i]), attributes: baseAttrs))
            i += 1
        }

        return result
    }

    // MARK: - Code block rendering

    private static func renderCodeBlock(_ code: String, language: String, isDark: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let codeFont = UIFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let bgColor = isDark ? UIColor(white: 0.08, alpha: 0.95) : UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1.0)
        let fgColor = isDark ? UIColor(white: 0.88, alpha: 1.0) : UIColor(white: 0.15, alpha: 1.0)

        let paraStyle = NSMutableParagraphStyle()
        paraStyle.firstLineHeadIndent = 12
        paraStyle.headIndent = 12
        paraStyle.tailIndent = -12
        paraStyle.lineSpacing = 2
        paraStyle.paragraphSpacingBefore = 4
        paraStyle.paragraphSpacing = 4

        // Language label
        if !language.isEmpty {
            let langAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: isDark ? UIColor(white: 0.5, alpha: 1) : UIColor(white: 0.55, alpha: 1),
                .backgroundColor: bgColor,
                .paragraphStyle: paraStyle
            ]
            result.append(NSAttributedString(string: "  \(language.uppercased())\n", attributes: langAttrs))
        }

        // Code content
        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: codeFont,
            .foregroundColor: fgColor,
            .backgroundColor: bgColor,
            .paragraphStyle: paraStyle
        ]
        result.append(NSAttributedString(string: code, attributes: codeAttrs))

        // Copy hint
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: isDark ? UIColor(white: 0.4, alpha: 1) : UIColor(white: 0.6, alpha: 1),
            .backgroundColor: bgColor,
            .paragraphStyle: paraStyle
        ]
        result.append(NSAttributedString(string: "\n  ⧉ Long press to copy", attributes: hintAttrs))

        return result
    }

    // MARK: - Helpers

    private static func newline(_ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: attrs)
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level > 0 && level <= 4 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, String(rest.dropFirst()))
    }

    private static func parseOrderedList(_ line: String) -> (Int, String)? {
        var numEnd = line.startIndex
        while numEnd < line.endIndex && line[numEnd].isNumber { numEnd = line.index(after: numEnd) }
        guard numEnd > line.startIndex && numEnd < line.endIndex && line[numEnd] == "." else { return nil }
        let afterDot = line.index(after: numEnd)
        guard afterDot < line.endIndex && line[afterDot] == " " else { return nil }
        let num = Int(line[line.startIndex..<numEnd]) ?? 0
        return (num, String(line[line.index(after: afterDot)...]))
    }

    private static func leadingSpaceCount(_ line: String) -> Int {
        var count = 0
        for ch in line { if ch == " " { count += 1 } else if ch == "\t" { count += 2 } else { break } }
        return count
    }

    private static func findClosing(_ marker: String, in chars: [Character], from start: Int) -> Int? {
        let markerChars = Array(marker)
        var i = start
        while i <= chars.count - markerChars.count {
            var matched = true
            for j in 0..<markerChars.count {
                if chars[i + j] != markerChars[j] { matched = false; break }
            }
            if matched && i > start { return i }
            i += 1
        }
        return nil
    }

    private static func findClosingSingle(_ ch: Character, in chars: [Character], from start: Int) -> Int? {
        for i in start..<chars.count {
            if chars[i] == ch && (i == start || chars[i-1] != "\\") { return i }
        }
        return nil
    }

    private static func parseLink(_ chars: [Character], from start: Int) -> (String, String, Int)? {
        guard chars[start] == "[" else { return nil }
        var i = start + 1
        // Find ]
        while i < chars.count && chars[i] != "]" { i += 1 }
        guard i < chars.count else { return nil }
        let text = String(chars[(start+1)..<i])
        i += 1 // skip ]
        guard i < chars.count && chars[i] == "(" else { return nil }
        i += 1 // skip (
        let urlStart = i
        while i < chars.count && chars[i] != ")" { i += 1 }
        guard i < chars.count else { return nil }
        let url = String(chars[urlStart..<i])
        return (text, url, i + 1)
    }
}

// MARK: - UIFont helpers

private extension UIFont {
    func bold() -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: d, size: 0)
    }
    func italic() -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(.traitItalic) else { return self }
        return UIFont(descriptor: d, size: 0)
    }
}
