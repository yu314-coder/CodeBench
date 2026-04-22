import Foundation
import PDFKit

struct RAGDocument: Codable, Identifiable {
    let id: UUID
    let filename: String
    let importedAt: Date
    var chunks: [RAGChunk]

    init(id: UUID = UUID(), filename: String, importedAt: Date = Date(), chunks: [RAGChunk] = []) {
        self.id = id
        self.filename = filename
        self.importedAt = importedAt
        self.chunks = chunks
    }
}

struct RAGChunk: Codable, Identifiable {
    let id: UUID
    let text: String
    let termFrequencies: [String: Int]

    init(id: UUID = UUID(), text: String, termFrequencies: [String: Int]) {
        self.id = id
        self.text = text
        self.termFrequencies = termFrequencies
    }
}

final class RAGEngine {
    static let shared = RAGEngine()

    private(set) var documents: [RAGDocument] = []
    private let maxChunks = 200
    private let storageFilename = "rag_index.json"
    private let ragEnabledKey = "rag.enabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: ragEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: ragEnabledKey) }
    }

    var totalChunkCount: Int {
        documents.reduce(0) { $0 + $1.chunks.count }
    }

    private init() {
        loadIndex()
    }

    // MARK: - Import

    func importDocument(text: String, filename: String) -> Bool {
        let chunks = chunkText(text)
        guard !chunks.isEmpty else { return false }

        // Check capacity
        let available = maxChunks - totalChunkCount
        let usableChunks = Array(chunks.prefix(available))
        guard !usableChunks.isEmpty else { return false }

        let doc = RAGDocument(filename: filename, chunks: usableChunks)
        documents.append(doc)
        saveIndex()
        return true
    }

    func removeDocument(id: UUID) {
        documents.removeAll { $0.id == id }
        saveIndex()
    }

    // MARK: - Query (BM25)

    func query(_ queryText: String, topK: Int = 3) -> [String] {
        let queryTerms = tokenize(queryText)
        guard !queryTerms.isEmpty else { return [] }

        let allChunks = documents.flatMap { $0.chunks }
        guard !allChunks.isEmpty else { return [] }

        let N = Double(allChunks.count)
        let avgdl = allChunks.reduce(0.0) { $0 + Double($1.termFrequencies.values.reduce(0, +)) } / max(1, N)
        let k1 = 1.5
        let b = 0.75

        // Compute IDF for query terms
        var idf: [String: Double] = [:]
        for term in queryTerms {
            let n = Double(allChunks.filter { $0.termFrequencies[term] != nil }.count)
            idf[term] = log((N - n + 0.5) / (n + 0.5) + 1.0)
        }

        // Score each chunk
        var scored: [(chunk: RAGChunk, score: Double)] = []
        for chunk in allChunks {
            let dl = Double(chunk.termFrequencies.values.reduce(0, +))
            var score = 0.0
            for term in queryTerms {
                let tf = Double(chunk.termFrequencies[term] ?? 0)
                let termIdf = idf[term] ?? 0
                score += termIdf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * dl / max(1, avgdl)))
            }
            if score > 0 {
                scored.append((chunk, score))
            }
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(topK).map { $0.chunk.text })
    }

    // MARK: - Chunking

    private func chunkText(_ text: String) -> [RAGChunk] {
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        var chunks: [RAGChunk] = []
        var currentChunk = ""

        for para in paragraphs {
            if currentChunk.count + para.count > 600 && !currentChunk.isEmpty {
                // Finalize current chunk
                chunks.append(makeChunk(currentChunk))
                // Overlap: keep last 50 chars
                let overlap = String(currentChunk.suffix(50))
                currentChunk = overlap + " " + para
            } else {
                if !currentChunk.isEmpty { currentChunk += "\n\n" }
                currentChunk += para
            }

            // If single paragraph exceeds limit, split at sentences
            if currentChunk.count > 600 {
                let sentences = splitSentences(currentChunk)
                var buffer = ""
                for sentence in sentences {
                    if buffer.count + sentence.count > 600 && !buffer.isEmpty {
                        chunks.append(makeChunk(buffer))
                        buffer = String(buffer.suffix(50)) + " " + sentence
                    } else {
                        if !buffer.isEmpty { buffer += " " }
                        buffer += sentence
                    }
                }
                currentChunk = buffer
            }
        }

        if !currentChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(makeChunk(currentChunk))
        }

        return chunks
    }

    private func makeChunk(_ text: String) -> RAGChunk {
        let terms = tokenize(text)
        var freq: [String: Int] = [:]
        for term in terms {
            freq[term, default: 0] += 1
        }
        return RAGChunk(text: text, termFrequencies: freq)
    }

    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
            }
        }
        return sentences.isEmpty ? [text] : sentences
    }

    // MARK: - Tokenization

    private static let stopWords: Set<String> = [
        "a", "an", "the", "is", "it", "in", "on", "at", "to", "for", "of", "and", "or",
        "but", "not", "with", "as", "by", "from", "that", "this", "was", "are", "were",
        "been", "be", "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "can", "shall", "if", "then", "than", "so", "no", "yes",
        "he", "she", "they", "we", "you", "i", "me", "my", "your", "his", "her", "its",
        "our", "their", "what", "which", "who", "whom", "when", "where", "why", "how",
        "all", "each", "every", "both", "few", "more", "most", "other", "some", "such",
        "only", "own", "same", "also", "just", "about", "up", "out", "into", "over",
        "after", "before", "between", "under", "again", "further", "once", "here", "there",
        "very", "too", "much", "many", "any", "still", "already", "while", "during"
    ]

    private func tokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
        return words.filter { !Self.stopWords.contains($0) }
    }

    // MARK: - Persistence

    private func storageURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(storageFilename)
    }

    private func loadIndex() {
        let url = storageURL()
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        documents = (try? decoder.decode([RAGDocument].self, from: data)) ?? []
    }

    private func saveIndex() {
        let url = storageURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(documents) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
