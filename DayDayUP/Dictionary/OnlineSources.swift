import Foundation
import SwiftUI
#if canImport(Translation)
import Translation
#endif

// MARK: - MyMemory

/// Free online translation memory. Anonymous use allows about 5,000 characters a day;
/// adding an email in Settings raises that to about 50,000.
struct MyMemoryClient {
    var email: String?

    private struct Response: Decodable {
        struct DataBlock: Decodable { var translatedText: String? }
        struct Match: Decodable { var translation: String? }
        var responseData: DataBlock?
        var matches: [Match]?
        var responseStatus: Int?
    }

    /// Returns the best translation first, followed by distinct alternatives.
    func translate(_ text: String, from: AppLanguage, to: AppLanguage) async throws -> [String] {
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")!
        var items = [URLQueryItem(name: "q", value: text),
                     URLQueryItem(name: "langpair", value: "\(from.myMemoryCode)|\(to.myMemoryCode)")]
        if let email, !email.isEmpty { items.append(URLQueryItem(name: "de", value: email)) }
        components.queryItems = items
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if let status = decoded.responseStatus, status != 200 {
            throw NSError(domain: "MyMemory", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "MyMemory couldn't translate this (status \(status)). The daily limit may be used up."])
        }
        var results: [String] = []
        let candidates = [decoded.responseData?.translatedText] + (decoded.matches ?? []).map(\.translation)
        for candidate in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            let lower = candidate.lowercased()
            guard !candidate.isEmpty, lower != text.lowercased(),
                  !results.contains(where: { $0.lowercased() == lower }) else { continue }
            results.append(candidate)
        }
        return Array(results.prefix(5))
    }
}

// MARK: - Wiktionary (English words)

/// English Wiktionary's definition endpoint: parts of speech and English definitions for English words.
struct WiktionaryClient {
    private struct Usage: Decodable {
        struct Definition: Decodable { var definition: String? }
        var partOfSpeech: String?
        var definitions: [Definition]?
    }

    func definitions(for word: String) async throws -> [(pos: String, english: String)] {
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        guard let url = URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/\(encoded)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("DayDayUP/1.0 (personal vocabulary app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let decoded = try JSONDecoder().decode([String: [Usage]].self, from: data)
        var results: [(String, String)] = []
        for usage in decoded["en"] ?? [] {
            let pos = Self.abbreviate(usage.partOfSpeech ?? "")
            for definition in (usage.definitions ?? []).prefix(2) {
                let text = Self.stripHTML(definition.definition ?? "")
                if !text.isEmpty { results.append((pos, text)) }
            }
        }
        return Array(results.prefix(8))
    }

    static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: ";", with: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func abbreviate(_ pos: String) -> String {
        switch pos.lowercased() {
        case "noun", "proper noun": return "n."
        case "verb": return "v."
        case "adjective": return "adj."
        case "adverb": return "adv."
        case "pronoun": return "pron."
        case "preposition": return "prep."
        case "conjunction": return "conj."
        case "interjection": return "int."
        default: return pos.isEmpty ? "" : String(pos.lowercased().prefix(4)) + "."
        }
    }
}

// MARK: - Apple Translation (iOS 18 / macOS 15 and later)

enum TranslationBridgeError: LocalizedError {
    case timedOut
    var errorDescription: String? { "Apple's translator didn't respond. Check that the language is downloaded in Settings → Translate." }
}

/// Apple's Translation framework only hands out a `TranslationSession` through the
/// `.translationTask` view modifier on iOS 18 / macOS 15. This bridge queues requests and lets a
/// hidden host view at the root of the app process them.
@available(iOS 18.0, macOS 15.0, *)
@MainActor
final class AppleTranslationBridge: ObservableObject {
    static let shared = AppleTranslationBridge()

    @Published var configuration: TranslationSession.Configuration?

    private struct Job {
        let id = UUID()
        let texts: [String]
        let source: Locale.Language
        let target: Locale.Language
        let continuation: CheckedContinuation<[String], Error>
    }

    private var jobs: [Job] = []

    func translate(_ texts: [String], from: AppLanguage, to: AppLanguage) async throws -> [String] {
        let source = Locale.Language(identifier: from.translationIdentifier)
        let target = Locale.Language(identifier: to.translationIdentifier)
        return try await withCheckedThrowingContinuation { continuation in
            let job = Job(texts: texts, source: source, target: target, continuation: continuation)
            jobs.append(job)
            schedule(source: source, target: target)
            // Never leave a caller hanging if the host view isn't on screen.
            let jobID = job.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.fail(jobID, TranslationBridgeError.timedOut)
            }
        }
    }

    private func schedule(source: Locale.Language, target: Locale.Language) {
        if let current = configuration, current.source == source, current.target == target {
            configuration?.invalidate()   // re-runs the task with the same languages
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs.remove(at: index).continuation.resume(throwing: error)
    }

    /// Called by the host view's `.translationTask`.
    func run(_ session: TranslationSession) async {
        guard let source = configuration?.source, let target = configuration?.target else { return }
        while let index = jobs.firstIndex(where: { $0.source == source && $0.target == target }) {
            let job = jobs.remove(at: index)
            do {
                let requests = job.texts.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                }
                let responses = try await session.translations(from: requests)
                var output = Array(repeating: "", count: job.texts.count)
                for response in responses {
                    if let i = Int(response.clientIdentifier ?? ""), i < output.count { output[i] = response.targetText }
                }
                job.continuation.resume(returning: output)
            } catch {
                job.continuation.resume(throwing: error)
            }
        }
        if let next = jobs.first { schedule(source: next.source, target: next.target) }
    }
}

@available(iOS 18.0, macOS 15.0, *)
private struct TranslationHost: View {
    @ObservedObject var bridge = AppleTranslationBridge.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(bridge.configuration) { session in
                await bridge.run(session)
            }
    }
}

extension View {
    /// Attach once near the root so Apple's translator can run on supported systems.
    @ViewBuilder
    func appleTranslationHost() -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            background(TranslationHost())
        } else {
            self
        }
    }
}
