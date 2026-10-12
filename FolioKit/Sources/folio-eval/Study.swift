import Foundation
import FolioKit

/// `folio-eval --search <folder> <search.json>`: how well searching finds the
/// right files in a labelled folder, by name (what the Library did before), by
/// the words in the files, by meaning (embeddings), and by both, using the
/// searches in Tools/TestSet/search.json.
enum SearchEval {
    struct File: Decodable {
        var queries: [Query]
    }

    struct Query: Decodable {
        var query: String
        var kind: String
        var relevant: [String]
    }

    struct Document {
        var path: String
        var subject: String
        var name: String
        var text: String
        var words: Set<String>
        var embedding: TextEmbedder.Embedding?
    }

    enum Method: String, CaseIterable {
        case name, words, meaning, both
    }

    @MainActor
    static func run(folder: URL, queriesURL: URL) async -> Int32 {
        guard let data = try? Data(contentsOf: queriesURL), let file = try? JSONDecoder().decode(File.self, from: data) else {
            print("Couldn't read \(queriesURL.path)")
            return 66
        }
        // Only schoolwork is filed, so only schoolwork is searched.
        let testFiles = Manifest.testFiles(in: [folder]).filter { $0.subject != nil }
        print("Reading \(testFiles.count) files…")
        let extractor = Extractor()
        let voter = ExampleVoter()
        var documents: [Document] = []
        for testFile in testFiles {
            let evidence = (try? await extractor.extract(from: testFile.url)) ?? Evidence(fileName: testFile.url.lastPathComponent, contentType: "public.data")
            let text = [evidence.readableFileName, evidence.title, evidence.text].compactMap { $0 }.joined(separator: "\n")
            documents.append(Document(
                path: testFile.path,
                subject: testFile.subject ?? "",
                name: testFile.url.lastPathComponent,
                text: text,
                words: Set(Self.words(text)),
                embedding: await voter.embedding(for: evidence)
            ))
        }
        let known = Set(documents.map(\.path))
        for query in file.queries {
            for path in query.relevant where !known.contains(path) {
                print("Warning: “\(query.query)” lists \(path), which isn't in the folder.")
            }
        }

        let ids = documents.map { _ in UUID() }
        let index = MeaningIndex(zip(ids, documents).compactMap { id, document in
            document.embedding.map { MeaningIndex.Item(id: id, embedding: $0) }
        })
        let embedder = TextEmbedder()
        var queryEmbeddings: [String: TextEmbedder.Embedding] = [:]
        for query in file.queries {
            queryEmbeddings[query.query] = await embedder.embed(query.query)
        }

        /// Every file's score for a query, by method.
        func scores(_ query: Query, method: Method) -> [Float] {
            switch method {
            case .name:
                return documents.map { $0.name.localizedStandardContains(query.query) ? 1 : 0 }
            case .words:
                return documents.map { wordScore(query.query, in: $0) }
            case .meaning:
                guard let embedding = queryEmbeddings[query.query] else { return documents.map { _ in -1 } }
                let similarity = Dictionary(uniqueKeysWithValues: index.matches(for: embedding, limit: documents.count, minimumSimilarity: -1).map { ($0.id, $0.similarity) })
                return ids.map { similarity[$0] ?? -1 }
            case .both:
                let meaning = scores(query, method: .meaning)
                let words = scores(query, method: .words)
                return zip(meaning, words).map { $0 + 0.5 * $1 }
            }
        }

        var lines = ["# Search", "", "\(documents.count) files, \(file.queries.count) searches. Hit@1 and hit@5: a relevant file is first, or in the top five. Recall@5: the share of relevant files in the top five. MRR: the mean of 1 ÷ the rank of the first relevant file.", ""]
        lines.append("| Method | Searches | Hit@1 | Hit@5 | Recall@5 | MRR |")
        lines.append("|---|---|---|---|---|---|")
        let positive = file.queries.filter { !$0.relevant.isEmpty }
        for method in Method.allCases {
            for kind in ["all"] + Array(Set(positive.map(\.kind))).sorted() {
                let chosen = kind == "all" ? positive : positive.filter { $0.kind == kind }
                var hit1 = 0, hit5 = 0, recall = 0.0, reciprocal = 0.0
                for query in chosen {
                    let ranking = ranked(scores(query, method: method))
                    let relevant = Set(query.relevant)
                    let positions = ranking.enumerated().filter { relevant.contains(documents[$0.element].path) }.map(\.offset)
                    if positions.first == 0 { hit1 += 1 }
                    if let first = positions.first, first < 5 { hit5 += 1 }
                    recall += Double(positions.filter { $0 < 5 }.count) / Double(relevant.count)
                    reciprocal += positions.first.map { 1 / Double($0 + 1) } ?? 0
                }
                let count = Double(max(chosen.count, 1))
                lines.append("| \(method.rawValue) (\(kind)) | \(chosen.count) | \(percent(Double(hit1) / count)) | \(percent(Double(hit5) / count)) | \(percent(recall / count)) | \(String(format: "%.2f", reciprocal / count)) |")
            }
        }

        // Folio's search, with a few settings: results it shows, how many are right, and how many it shows when nothing is relevant.
        lines += ["", "## LibrarySearch settings", "", "Shown: results above the cut-off, at most 10. Wrong shown: shown results that aren't relevant, per search. Shown for none: results shown for searches with nothing relevant.", ""]
        lines += ["| Meaning weight | Minimum words | Hit@1 | Hit@5 | Recall@5 | MRR | Shown | Wrong shown | Shown for none |", "|---|---|---|---|---|---|---|---|---|"]
        let searchDocuments = zip(ids, documents).map { id, document in
            LibrarySearch.Document(id: id, name: document.name, text: document.text, embedding: document.embedding)
        }
        for weight in [0.0, 0.3, 0.5] {
            for minimum in [0.34, 0.4, 0.5] {
                var settings = LibrarySearch.Settings()
                settings.meaningWeight = weight
                settings.minimumWords = minimum
                let search = LibrarySearch(searchDocuments, settings: settings)
                var hit1 = 0, hit5 = 0, recall = 0.0, reciprocal = 0.0, shown = 0, wrong = 0, shownForNone = 0
                for query in file.queries {
                    let results = search.search(query.query, queryEmbedding: queryEmbeddings[query.query], limit: 10)
                    let paths = results.compactMap { result in ids.firstIndex(of: result.id).map { documents[$0].path } }
                    let relevant = Set(query.relevant)
                    if relevant.isEmpty {
                        shownForNone += paths.count
                        continue
                    }
                    shown += paths.count
                    wrong += paths.filter { !relevant.contains($0) }.count
                    let positions = paths.enumerated().filter { relevant.contains($0.element) }.map(\.offset)
                    if positions.first == 0 { hit1 += 1 }
                    if let first = positions.first, first < 5 { hit5 += 1 }
                    recall += Double(positions.filter { $0 < 5 }.count) / Double(relevant.count)
                    reciprocal += positions.first.map { 1 / Double($0 + 1) } ?? 0
                }
                let count = Double(max(positive.count, 1))
                let negatives = Double(max(file.queries.count - positive.count, 1))
                lines.append("| \(weight) | \(minimum) | \(percent(Double(hit1) / count)) | \(percent(Double(hit5) / count)) | \(percent(recall / count)) | \(String(format: "%.2f", reciprocal / count)) | \(String(format: "%.1f", Double(shown) / count)) | \(String(format: "%.1f", Double(wrong) / count)) | \(String(format: "%.1f", Double(shownForNone) / negatives)) |")
            }
        }
        let search = LibrarySearch(searchDocuments)
        var relatedSame = 0, relatedCount = 0
        for (offset, id) in ids.enumerated() {
            for result in search.related(to: id, limit: 3) {
                guard let other = ids.firstIndex(of: result.id) else { continue }
                relatedCount += 1
                if documents[other].subject == documents[offset].subject { relatedSame += 1 }
            }
        }
        lines += ["", "LibrarySearch related files: \(relatedSame) of \(relatedCount) are in the file's subject (\(percent(Double(relatedSame) / Double(max(relatedCount, 1))))), from \(ids.count) files."]

        // The default settings' results for each search, to read.
        lines += ["", "## LibrarySearch results (default settings)", ""]
        for query in file.queries {
            let results = search.search(query.query, queryEmbedding: queryEmbeddings[query.query], limit: 5)
            let relevant = Set(query.relevant)
            let shownResults = results.compactMap { result -> String? in
                guard let index = ids.firstIndex(of: result.id) else { return nil }
                return "\(relevant.contains(documents[index].path) ? "✓" : "✗") \(documents[index].name) (\(String(format: "%.2f", result.score)))"
            }
            lines.append("- \(query.query) [\(query.kind)]: \(shownResults.isEmpty ? "nothing" : shownResults.joined(separator: ", "))")
        }

        // How alike the best wrong file is, against the best right one, to choose a cut-off.
        lines += ["", "## Meaning: best right and best wrong similarity", "", "| Search | Kind | Best right | Best wrong | Top 3 |", "|---|---|---|---|---|"]
        for query in file.queries {
            let meaning = scores(query, method: .meaning)
            let relevant = Set(query.relevant)
            let right = documents.indices.filter { relevant.contains(documents[$0].path) }.map { meaning[$0] }.max()
            let wrong = documents.indices.filter { !relevant.contains(documents[$0].path) }.map { meaning[$0] }.max()
            let top = ranked(meaning).prefix(3).map { "\(documents[$0].name) (\(String(format: "%.2f", meaning[$0])))" }.joined(separator: ", ")
            lines.append("| \(query.query) | \(query.kind) | \(right.map { String(format: "%.2f", $0) } ?? "–") | \(wrong.map { String(format: "%.2f", $0) } ?? "–") | \(top) |")
        }

        // Related files: are a file's closest files from the same subject?
        var sameSubject = 0, related = 0
        for (offset, id) in ids.enumerated() {
            for match in index.related(to: id, limit: 3, minimumSimilarity: -1) {
                guard let other = ids.firstIndex(of: match.id) else { continue }
                related += 1
                if documents[other].subject == documents[offset].subject { sameSubject += 1 }
            }
        }
        lines += ["", "Related files: \(sameSubject) of \(related) of the three closest files to each file are in its subject (\(percent(Double(sameSubject) / Double(max(related, 1)))))."]

        let report = lines.joined(separator: "\n")
        print(report)
        return 0
    }

    /// File indices, best score first.
    static func ranked(_ scores: [Float]) -> [Int] {
        scores.indices.sorted { scores[$0] > scores[$1] }
    }

    /// The share of the search's words found in the file, allowing different endings.
    static func wordScore(_ query: String, in document: Document) -> Float {
        let wanted = words(query).filter { $0.count >= 3 && !["the", "and", "how", "for", "with", "can", "his", "its"].contains($0) }
        guard !wanted.isEmpty else { return 0 }
        let found = wanted.filter { word in
            document.words.contains(word) || document.words.contains { $0.count >= 5 && word.count >= 5 && $0.prefix(5) == word.prefix(5) }
        }
        return Float(found.count) / Float(wanted.count)
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// `folio-eval --cards <cards.json>`: writes flashcards from each note in
/// Tools/TestSet/cards.json with the on-device AI, and reports what was kept,
/// what was dropped and why, and how long it took, with every card for reading.
enum CardEval {
    struct File: Decodable {
        var notes: [Note]
    }

    struct Note: Decodable {
        var id: String
        var subject: String
        var text: String
        var expectsCards: Bool?
    }

    static func run(_ url: URL, options: CardWriter.Options = CardWriter.Options()) async -> Int32 {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            print("Couldn't read \(url.path)")
            return 66
        }
        let writer = CardWriter(options: options)
        if let reason = await writer.unavailableReason {
            print("The on-device AI isn't available: \(reason)")
            return 69
        }
        var summary = ["| Note | Characters | Looks like questions | Parts | Kept | Not in notes | Repeats | Malformed | Declined parts | Seconds |", "|---|---|---|---|---|---|---|---|---|---|"]
        var details: [String] = []
        let clock = ContinuousClock()
        var totals = (kept: 0, dropped: 0, seconds: 0.0)
        for note in file.notes {
            let start = clock.now
            let result = await writer.cards(from: note.text, subject: note.subject)
            let seconds = (clock.now - start).seconds
            totals.kept += result.drafts.count
            totals.dropped += result.notInNotes + result.repeats + result.malformed
            totals.seconds += seconds
            summary.append("| \(note.id)\(note.expectsCards == false ? " (few answers)" : "") | \(note.text.count) | \(CardWriter.looksLikeQuestions(note.text) ? "yes" : "no") | \(result.partsRead) | \(result.drafts.count) | \(result.notInNotes) | \(result.repeats) | \(result.malformed) | \(result.partsDeclined) | \(String(format: "%.1f", seconds)) |")
            details.append("## \(note.id)\n")
            if let problem = result.problem { details.append("Problem: \(problem.message)\n") }
            for draft in result.drafts {
                details.append("- **\(draft.question)** \(draft.answer)\(draft.quote.map { "  \n  _\($0)_" } ?? "")")
            }
            details.append("")
            print("\(note.id): \(result.drafts.count) kept, \(result.notInNotes) not in notes, \(result.repeats) repeats, \(result.malformed) malformed, \(result.partsDeclined) declined parts, \(String(format: "%.1f", seconds)) s")
        }
        let report = (["# Flashcards", "", "Kept \(totals.kept), dropped \(totals.dropped), \(String(format: "%.0f", totals.seconds)) s in all.", ""] + summary + [""] + details).joined(separator: "\n")
        print("\n" + report)
        return 0
    }
}
