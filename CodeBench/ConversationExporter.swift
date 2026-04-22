import UIKit

enum ConversationExporter {

    static func markdownString(from messages: [ChatMessage], title: String) -> String {
        var md = "# \(title)\n\n"
        md += "_Exported from CodeBench_\n\n---\n\n"
        for message in messages where message.role != .system {
            let role = message.role == .user ? "**You**" : "**Assistant**"
            md += "\(role)\n\n\(message.content)\n\n---\n\n"
        }
        return md
    }

    static func plainTextString(from messages: [ChatMessage], title: String) -> String {
        var text = "\(title)\n"
        text += String(repeating: "=", count: title.count) + "\n\n"
        for message in messages where message.role != .system {
            let role = message.role == .user ? "You" : "Assistant"
            text += "[\(role)]\n\(message.content)\n\n"
        }
        return text
    }

    static func pdfData(from messages: [ChatMessage], title: String) -> Data {
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 50
        let textWidth = pageWidth - margin * 2
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let titleFont = UIFont.systemFont(ofSize: 20, weight: .bold)
        let roleFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: 12)
        let textColor = UIColor.black
        let mutedColor = UIColor.darkGray

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        return renderer.pdfData { context in
            var currentY: CGFloat = 0

            func ensurePage(height: CGFloat) {
                if currentY == 0 || currentY + height > pageHeight - margin {
                    context.beginPage()
                    currentY = margin
                }
            }

            // Title page
            ensurePage(height: 60)
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: textColor]
            let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
            let titleRect = CGRect(x: margin, y: currentY, width: textWidth, height: 30)
            titleStr.draw(in: titleRect)
            currentY += 40

            let subtitleAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: mutedColor]
            let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short)
            let subtitleStr = NSAttributedString(string: "Exported from CodeBench • \(dateStr)", attributes: subtitleAttrs)
            subtitleStr.draw(in: CGRect(x: margin, y: currentY, width: textWidth, height: 20))
            currentY += 30

            // Messages
            for message in messages where message.role != .system {
                let roleName = message.role == .user ? "You" : "Assistant"
                let roleAttrs: [NSAttributedString.Key: Any] = [.font: roleFont, .foregroundColor: WorkspaceStyle.accent]
                let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: textColor]

                let roleStr = NSAttributedString(string: roleName, attributes: roleAttrs)
                let bodyStr = NSAttributedString(string: message.content, attributes: bodyAttrs)

                let bodyBound = bodyStr.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)

                let blockHeight = 20 + bodyBound.height + 16

                ensurePage(height: min(blockHeight, pageHeight - margin * 2))

                roleStr.draw(in: CGRect(x: margin, y: currentY, width: textWidth, height: 18))
                currentY += 20

                // Draw body, handling page breaks for long messages
                let lines = message.content.components(separatedBy: "\n")
                for line in lines {
                    let lineStr = NSAttributedString(string: line, attributes: bodyAttrs)
                    let lineBound = lineStr.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                    let lineHeight = max(lineBound.height, 16)

                    ensurePage(height: lineHeight)
                    lineStr.draw(in: CGRect(x: margin, y: currentY, width: textWidth, height: lineHeight))
                    currentY += lineHeight
                }

                currentY += 16
            }
        }
    }
}
