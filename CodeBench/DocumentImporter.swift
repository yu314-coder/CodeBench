import UIKit
import UniformTypeIdentifiers
import PDFKit

protocol DocumentImporterDelegate: AnyObject {
    func documentImporter(_ importer: DocumentImporter, didImportText text: String, filename: String)
    func documentImporter(_ importer: DocumentImporter, didFailWith error: String)
}

final class DocumentImporter: NSObject, UIDocumentPickerDelegate {
    weak var delegate: DocumentImporterDelegate?
    private weak var presenter: UIViewController?

    init(presenter: UIViewController) {
        self.presenter = presenter
        super.init()
    }

    func presentPicker(types: [UTType] = [.pdf, .plainText, .utf8PlainText, .text],
                       allowsMultiple: Bool = false) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = allowsMultiple
        picker.modalPresentationStyle = .formSheet
        presenter?.present(picker, animated: true)
    }

    /// Broad type set for AI-chat attachments: PDFs, any text/source file
    /// (code, json, csv, xml, markdown, ...), plus `.data` as a catch-all
    /// so nothing is greyed out. Non-text picks fail gracefully in
    /// `extractPlainText` and surface via `didFailWith`.
    func presentAttachmentPicker() {
        presentPicker(types: [
            .pdf, .pythonScript, .sourceCode, .swiftSource, .cSource,
            .cPlusPlusSource, .cHeader, .cPlusPlusHeader, .shellScript,
            .json, .xml, .html, .javaScript, .commaSeparatedText,
            .plainText, .utf8PlainText, .utf16PlainText, .text, .data,
        ], allowsMultiple: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // Fires the delegate once per file (the AI-attachment picker allows
        // multi-select; the default single-select picker yields one URL).
        for url in urls {
            let filename = url.lastPathComponent
            if url.pathExtension.lowercased() == "pdf" {
                extractPDFText(from: url, filename: filename)
            } else {
                extractPlainText(from: url, filename: filename)
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}

    private func extractPDFText(from url: URL, filename: String) {
        guard let document = PDFDocument(url: url) else {
            delegate?.documentImporter(self, didFailWith: "Could not open PDF.")
            return
        }
        var fullText = ""
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let text = page.string {
                fullText += text + "\n\n"
            }
        }
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delegate?.documentImporter(self, didFailWith: "PDF contains no extractable text.")
        } else {
            delegate?.documentImporter(self, didImportText: trimmed, filename: filename)
        }
    }

    private func extractPlainText(from url: URL, filename: String) {
        // Guard against slurping a huge / binary file into memory.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 5_000_000 {
            delegate?.documentImporter(self, didFailWith: "\(filename): file too large (\(size / 1_000_000) MB).")
            return
        }
        do {
            // Try UTF-8 first, then a lenient fallback so Latin-1 / Windows
            // text files still import rather than failing as "binary".
            let text: String
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                text = utf8
            } else {
                text = try String(contentsOf: url, encoding: .isoLatin1)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                delegate?.documentImporter(self, didFailWith: "File is empty.")
            } else {
                delegate?.documentImporter(self, didImportText: trimmed, filename: filename)
            }
        } catch {
            delegate?.documentImporter(self, didFailWith: "Could not read file: \(error.localizedDescription)")
        }
    }
}
