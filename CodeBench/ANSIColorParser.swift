import UIKit

/// Parse ANSI SGR escape sequences (`ESC[…m`) into attributed-string spans.
///
/// This is a pragmatic subset — enough to render the output of `rich`,
/// `pytest`, `colorama`, `pip`, `tqdm` and the stdout of most terminal
/// tools. Handles:
///   * 3-bit standard foreground / background (30-37, 40-47)
///   * Bright variants (90-97, 100-107)
///   * 8-bit `38;5;N` / `48;5;N` indexed colour
///   * 24-bit `38;2;R;G;B` / `48;2;R;G;B` truecolor
///   * Bold (1) / dim (2) / italic (3) / underline (4) / reverse (7)
///   * Reset (0 and plain `ESC[m`)
/// Cursor-movement sequences (K, J, H, A..D, etc.) are stripped silently
/// because a text view can't represent them — the line-overwrite case
/// (used by tqdm) is handled via `\r` in the caller.
enum ANSI {

    struct State: Equatable {
        var fg: UIColor?
        var bg: UIColor?
        var bold: Bool = false
        var italic: Bool = false
        var underline: Bool = false
        var dim: Bool = false
        var reverse: Bool = false
    }

    /// Parse `text` and produce an `NSAttributedString` using the supplied
    /// font + default foreground. Returns the final state so a caller that
    /// streams chunks can carry coloring across `appendToTerminal` calls.
    static func parse(
        _ text: String,
        font: UIFont,
        defaultColor: UIColor,
        initialState: State = State()
    ) -> (attributed: NSAttributedString, finalState: State) {

        let out = NSMutableAttributedString()
        var state = initialState
        var i = text.startIndex

        while i < text.endIndex {
            // Search for the next ESC (0x1B)
            if let esc = text[i...].firstIndex(of: "\u{1b}") {
                // Emit everything before ESC with current state
                if esc > i {
                    let run = String(text[i..<esc])
                    out.append(attributed(run, font: font, defaultColor: defaultColor, state: state))
                }
                // Parse the escape sequence starting at `esc`
                if let (consumed, newState) = parseEscape(text: text, from: esc, current: state) {
                    state = newState
                    i = consumed
                } else {
                    // Unrecognised — drop the ESC byte and continue
                    i = text.index(after: esc)
                }
            } else {
                // No more escapes — emit the rest and exit
                let run = String(text[i...])
                if !run.isEmpty {
                    out.append(attributed(run, font: font, defaultColor: defaultColor, state: state))
                }
                break
            }
        }

        return (out, state)
    }

    // MARK: - Attribute application

    private static func attributed(
        _ s: String,
        font: UIFont,
        defaultColor: UIColor,
        state: State
    ) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [:]

        // Font (with bold/italic traits)
        var descriptor = font.fontDescriptor
        var traits: UIFontDescriptor.SymbolicTraits = []
        if state.bold { traits.insert(.traitBold) }
        if state.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let withTraits = descriptor.withSymbolicTraits(traits) {
            descriptor = withTraits
        }
        attrs[.font] = UIFont(descriptor: descriptor, size: font.pointSize)

        // Color — honor reverse by swapping fg/bg
        var fg = state.fg ?? defaultColor
        var bg = state.bg
        if state.reverse {
            let oldFg = fg
            fg = bg ?? UIColor.black
            bg = oldFg
        }
        if state.dim { fg = fg.withAlphaComponent(0.55) }
        attrs[.foregroundColor] = fg
        if let bg = bg { attrs[.backgroundColor] = bg }

        if state.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        return NSAttributedString(string: s, attributes: attrs)
    }

    // MARK: - Escape parsing

    /// Parse an ANSI escape starting at `start` (which must point at ESC
    /// 0x1B). Returns the index of the character after the sequence plus
    /// the new style state, or nil if the sequence is unrecognised.
    private static func parseEscape(
        text: String,
        from start: String.Index,
        current: State
    ) -> (end: String.Index, state: State)? {
        var i = text.index(after: start)
        guard i < text.endIndex else { return nil }

        // CSI — ESC [
        if text[i] == "[" {
            i = text.index(after: i)
            // Collect digits + ';' until a final byte (a letter)
            var params = ""
            while i < text.endIndex {
                let ch = text[i]
                if ch.isLetter {
                    // Consume the final byte
                    let final = ch
                    let end = text.index(after: i)

                    switch final {
                    case "m":
                        // SGR
                        let newState = applySGR(params: params, current: current)
                        return (end, newState)
                    default:
                        // Cursor-movement or erase — drop silently
                        return (end, current)
                    }
                } else if ch == ";" || ch.isNumber || ch == "?" || ch == ">" {
                    params.append(ch)
                    i = text.index(after: i)
                } else {
                    // Bail — unknown byte
                    return nil
                }
            }
            return nil  // Ran off end of string mid-sequence
        }

        // OSC — ESC ] … BEL or ESC \
        if text[i] == "]" {
            // Title-setting etc. Skip to BEL (0x07) or ST (ESC \)
            var j = text.index(after: i)
            while j < text.endIndex {
                if text[j] == "\u{07}" {  // BEL
                    return (text.index(after: j), current)
                }
                if text[j] == "\u{1b}" {
                    let k = text.index(after: j)
                    if k < text.endIndex, text[k] == "\\" {
                        return (text.index(after: k), current)
                    }
                }
                j = text.index(after: j)
            }
            return nil
        }

        // ESC <single char> (plain fe, like ESC =, ESC >) — drop two bytes
        return (text.index(after: i), current)
    }

    private static func applySGR(params: String, current: State) -> State {
        var state = current
        let raw = params.isEmpty ? "0" : params
        let codes = raw.split(separator: ";").map { Int($0) ?? 0 }

        var i = 0
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0:
                state = State()
            case 1: state.bold = true
            case 2: state.dim = true
            case 3: state.italic = true
            case 4: state.underline = true
            case 7: state.reverse = true
            case 22: state.bold = false; state.dim = false
            case 23: state.italic = false
            case 24: state.underline = false
            case 27: state.reverse = false

            case 30...37:  // standard foreground
                state.fg = standardColor(c - 30, bright: false)
            case 39:
                state.fg = nil
            case 40...47:  // standard background
                state.bg = standardColor(c - 40, bright: false)
            case 49:
                state.bg = nil

            case 90...97:  // bright foreground
                state.fg = standardColor(c - 90, bright: true)
            case 100...107:  // bright background
                state.bg = standardColor(c - 100, bright: true)

            case 38:
                // 38;5;N  or  38;2;R;G;B
                if i + 1 < codes.count, codes[i + 1] == 5, i + 2 < codes.count {
                    state.fg = xterm256(codes[i + 2])
                    i += 2
                } else if i + 1 < codes.count, codes[i + 1] == 2, i + 4 < codes.count {
                    state.fg = UIColor(red: CGFloat(codes[i + 2]) / 255,
                                        green: CGFloat(codes[i + 3]) / 255,
                                        blue: CGFloat(codes[i + 4]) / 255, alpha: 1)
                    i += 4
                }
            case 48:
                if i + 1 < codes.count, codes[i + 1] == 5, i + 2 < codes.count {
                    state.bg = xterm256(codes[i + 2])
                    i += 2
                } else if i + 1 < codes.count, codes[i + 1] == 2, i + 4 < codes.count {
                    state.bg = UIColor(red: CGFloat(codes[i + 2]) / 255,
                                        green: CGFloat(codes[i + 3]) / 255,
                                        blue: CGFloat(codes[i + 4]) / 255, alpha: 1)
                    i += 4
                }

            default:
                break
            }
            i += 1
        }
        return state
    }

    // MARK: - Color palettes

    /// VS-Code-style palette for the 16 standard ANSI colors. Tuned to
    /// look right on the dark #0a0a0f terminal background (bright enough
    /// to stand out, not neon).
    private static func standardColor(_ idx: Int, bright: Bool) -> UIColor {
        // idx ∈ 0..7 for {black, red, green, yellow, blue, magenta, cyan, white}
        let palette: [(CGFloat, CGFloat, CGFloat)] = bright ? [
            (0.33, 0.33, 0.35),  // bright black (gray)
            (0.98, 0.42, 0.43),  // bright red
            (0.38, 0.86, 0.50),  // bright green
            (0.98, 0.80, 0.31),  // bright yellow
            (0.44, 0.65, 1.00),  // bright blue
            (0.79, 0.53, 0.99),  // bright magenta
            (0.47, 0.82, 0.93),  // bright cyan
            (0.95, 0.95, 0.95),  // bright white
        ] : [
            (0.00, 0.00, 0.00),  // black
            (0.82, 0.28, 0.31),  // red
            (0.24, 0.70, 0.36),  // green
            (0.83, 0.65, 0.20),  // yellow
            (0.29, 0.51, 0.90),  // blue
            (0.64, 0.37, 0.86),  // magenta
            (0.29, 0.67, 0.78),  // cyan
            (0.80, 0.80, 0.80),  // white
        ]
        let i = max(0, min(7, idx))
        let (r, g, b) = palette[i]
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// xterm 256-color palette — used by rich, pytest, etc.
    private static func xterm256(_ n: Int) -> UIColor {
        if n < 16 {
            return standardColor(n & 7, bright: n >= 8)
        }
        if n >= 16 && n <= 231 {
            // 6×6×6 cube
            let idx = n - 16
            let r = idx / 36
            let g = (idx / 6) % 6
            let b = idx % 6
            let levels: [CGFloat] = [0, 0.373, 0.525, 0.678, 0.827, 1.0]
            return UIColor(red: levels[r], green: levels[g], blue: levels[b], alpha: 1)
        }
        if n >= 232 && n <= 255 {
            // grayscale
            let v = CGFloat(n - 232) / 23.0
            return UIColor(red: v, green: v, blue: v, alpha: 1)
        }
        return .white
    }
}
