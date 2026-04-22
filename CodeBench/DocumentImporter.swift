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

    func presentPicker() {
        let types: [UTType] = [.pdf, .plainText, .utf8PlainText, .text]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .formSheet
        presenter?.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let filename = url.lastPathComponent

        if url.pathExtension.lowercased() == "pdf" {
            extractPDFText(from: url, filename: filename)
        } else {
            extractPlainText(from: url, filename: filename)
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
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
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
