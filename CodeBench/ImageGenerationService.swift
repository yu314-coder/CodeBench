import Foundation

enum ImageGenerationService {
    private static let imageKeywords = [
        "draw", "sketch", "illustrate", "paint", "generate image",
        "create image", "create picture", "make image", "make picture",
        "create illustration", "make illustration", "diagram",
        "generate a picture", "draw me", "create a diagram",
        "make a diagram", "design a logo", "create a logo",
        "visualize", "make art", "create art", "generate art"
    ]

    static func detectImageRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        return imageKeywords.contains { lower.contains($0) }
    }

    static func imagePromptAugmentation() -> String {
        return """
        When asked to create visual content, generate SVG markup wrapped in ```svg code blocks. \
        Keep SVGs clean with basic shapes (rect, circle, ellipse, line, polyline, polygon, path, text). \
        Use a viewBox of "0 0 400 300". Include fills and strokes with modern colors. \
        Do not use external images or fonts.
        """
    }

    static func extractSVG(_ text: String) -> String? {
        // Try fenced code block first: ```svg ... ```
        if let range = text.range(of: "```svg\\s*\\n([\\s\\S]*?)```", options: .regularExpression) {
            let match = String(text[range])
            let cleaned = match
                .replacingOccurrences(of: "```svg", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.contains("<svg") { return cleaned }
        }
        // Try raw <svg> tag
        if let start = text.range(of: "<svg", options: .caseInsensitive),
           let end = text.range(of: "</svg>", options: .caseInsensitive) {
            let svgRange = start.lowerBound..<end.upperBound
            return String(text[svgRange])
        }
        return nil
    }
}
