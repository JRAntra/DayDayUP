import Foundation

// MARK: - Source settings (Settings → Dictionary sources)

enum LookupSourceKind: String, Codable, CaseIterable, Identifiable {
    case localDictionary, wiktionary, wikipedia, appleTranslator, myMemory
    var id: String { rawValue }

    /// The short name shown above this source's results in the Add sheet.
    var shortTitle: String {
        switch self {
        case .localDictionary: return "Offline dictionary"
        case .wiktionary: return "Wiktionary"
        case .wikipedia: return "Wikipedia"
        case .appleTranslator: return "Apple Translate"
        case .myMemory: return "MyMemory"
        }
    }

    var title: String {
        switch self {
        case .localDictionary: return "Offline dictionaries"
        case .wiktionary: return "Wiktionary (English words)"
        case .wikipedia: return "Wikipedia (terms and names)"
        case .appleTranslator: return "Apple Translate"
        case .myMemory: return "MyMemory"
        }
    }

    var detail: String {
        switch self {
        case .localDictionary: return "Instant and offline. Multiple meanings with parts of speech."
        case .wiktionary: return "Online English definitions when the offline dictionary has no entry."
        case .wikipedia: return "Technical terms and tool names: a one-line explanation and the name in your other language."
        case .appleTranslator: return "On-device translation. Needs iOS 18 or macOS 15."
        case .myMemory: return "Online translation with alternatives. Daily limit applies."
        }
    }
}

struct LookupSourceSetting: Codable, Identifiable, Hashable {
    var kind: LookupSourceKind
    var enabled: Bool
    var id: String { kind.rawValue }
}

@MainActor
final class LookupSourceSettings: ObservableObject {
    @Published var sources: [LookupSourceSetting] { didSet { persist() } }
    @Published var myMemoryEmail: String { didSet { UserDefaults.standard.set(myMemoryEmail, forKey: Self.emailKey) } }

    private static let key = "lookup.sources"
    private static let emailKey = "lookup.myMemoryEmail"

    static let defaults: [LookupSourceSetting] = [
        .init(kind: .localDictionary, enabled: true),
        .init(kind: .wiktionary, enabled: true),
        .init(kind: .wikipedia, enabled: true),
        .init(kind: .appleTranslator, enabled: true),
        .init(kind: .myMemory, enabled: true),
    ]

    init() {
        sources = Self.loadSources()
        myMemoryEmail = UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
    }

    private static func loadSources() -> [LookupSourceSetting] {
        guard let data = UserDefaults.standard.data(forKey: key),
              var saved = try? JSONDecoder().decode([LookupSourceSetting].self, from: data) else { return defaults }
        for item in defaults where !saved.contains(where: { $0.kind == item.kind }) { saved.append(item) }
        return saved
    }

    /// Re-reads settings after a backup restore.
    func reload() {
        sources = Self.loadSources()
        myMemoryEmail = UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func isEnabled(_ kind: LookupSourceKind) -> Bool { sources.first { $0.kind == kind }?.enabled ?? false }
    var ordered: [LookupSourceKind] { sources.filter(\.enabled).map(\.kind) }

    func resetToDefaults() { sources = Self.defaults }
}

// MARK: - Lookup

/// One web source's part of a lookup in the Add sheet.
struct WebResult: Identifiable {
    enum State: Equatable {
        case searching
        case found
        case nothing
        /// Didn't answer within `LookupSession.webTimeout`.
        case noAnswer
    }

    let kind: LookupSourceKind
    var state: State = .searching
    var candidates: [LookupCandidate] = []
    var id: String { kind.rawValue }
}

/// Everything the Add sheet shows for one word (see LOOKUP_AND_REFERENCE.md).
/// The offline dictionary answers at once; web sources answer while the sheet is open.
@MainActor
final class LookupSession: ObservableObject, Identifiable {
    nonisolated static let webTimeout: UInt64 = 10_000_000_000

    let id = UUID()
    /// What was typed.
    let typed: String
    /// The word already saved in this category, if any.
    let existing: WordMO?
    /// The dictionary's spelling when it had the exact word, otherwise what was typed.
    let headword: String
    /// Meanings from the offline dictionary (exact match only).
    let local: [LookupCandidate]
    /// Similar words when the dictionary has no exact match.
    let suggestions: [String]
    /// Shown when there's nothing else to say, e.g. "install the dictionary".
    let hint: String?
    /// The enabled web sources that apply to this language, in Settings order.
    let webKinds: [LookupSourceKind]

    @Published private(set) var web: [WebResult] = []
    @Published private(set) var webStarted = false

    private let fetch: (LookupSourceKind) async -> [LookupCandidate]
    private var tasks: [Task<Void, Never>] = []

    init(typed: String, existing: WordMO?, headword: String, local: [LookupCandidate], suggestions: [String],
         hint: String?, webKinds: [LookupSourceKind], fetch: @escaping (LookupSourceKind) async -> [LookupCandidate]) {
        self.typed = typed
        self.existing = existing
        self.headword = headword
        self.local = local
        self.suggestions = suggestions
        self.hint = hint
        self.webKinds = webKinds
        self.fetch = fetch
    }

    /// The name the word is saved under.
    var term: String { existing?.termValue ?? headword }
    /// No exact match but similar words exist, so the typed word may be misspelled.
    var mayBeMisspelled: Bool { local.isEmpty && !suggestions.isEmpty }
    var allCandidates: [LookupCandidate] { local + web.flatMap(\.candidates) }
    var webFinished: Bool { webStarted && !web.contains { $0.state == .searching } }

    /// Asks every web source at once; each one's answer appears as it arrives.
    func searchWeb() {
        guard !webStarted else { return }
        webStarted = true
        web = webKinds.map { WebResult(kind: $0) }
        for kind in webKinds {
            let fetch = self.fetch
            // Two separate tasks rather than a task group: a group waits for all its children, and
            // Apple's translator can't be cancelled, so the timeout would only show once it answered.
            tasks.append(Task { [weak self] in
                let answer = await fetch(kind)
                guard !Task.isCancelled else { return }
                self?.finish(kind, answer)
            })
            tasks.append(Task { [weak self] in
                try? await Task.sleep(nanoseconds: LookupSession.webTimeout)
                guard !Task.isCancelled else { return }
                self?.timeOut(kind)
            })
        }
    }

    /// A late answer still replaces "No answer".
    private func finish(_ kind: LookupSourceKind, _ answer: [LookupCandidate]) {
        guard let index = web.firstIndex(where: { $0.kind == kind }) else { return }
        web[index].candidates = answer
        web[index].state = answer.isEmpty ? .nothing : .found
    }

    private func timeOut(_ kind: LookupSourceKind) {
        guard let index = web.firstIndex(where: { $0.kind == kind }), web[index].state == .searching else { return }
        web[index].state = .noAnswer
    }

    /// Stops the web search (the sheet closed, or a similar word was picked).
    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }
}

/// Translates English explanations into another language, preferring Apple's on-device
/// translator and falling back to MyMemory.
@MainActor
struct Translator {
    let settings: LookupSourceSettings

    var appleAvailable: Bool {
        if #available(iOS 18.0, macOS 15.0, *) { return settings.isEnabled(.appleTranslator) }
        return false
    }

    func translate(_ texts: [String], from: AppLanguage, to: AppLanguage) async -> [String]? {
        guard !texts.isEmpty else { return [] }
        if appleAvailable, #available(iOS 18.0, macOS 15.0, *) {
            if let output = try? await AppleTranslationBridge.shared.translate(texts, from: from, to: to),
               output.contains(where: { !$0.isEmpty }) {
                return output
            }
        }
        if settings.isEnabled(.myMemory) {
            let client = MyMemoryClient(email: settings.myMemoryEmail)
            var output: [String] = []
            for text in texts {
                output.append((try? await client.translate(text, from: from, to: to))?.first ?? "")
            }
            if output.contains(where: { !$0.isEmpty }) { return output }
        }
        return nil
    }
}

@MainActor
final class LookupService: ObservableObject {
    let dictionaries: DictionaryManager
    let settings: LookupSourceSettings

    init(dictionaries: DictionaryManager, settings: LookupSourceSettings) {
        self.dictionaries = dictionaries
        self.settings = settings
    }

    private var translator: Translator { Translator(settings: settings) }

    /// Looks a word up in the offline dictionary. When it has no exact match, the Add sheet then asks
    /// every enabled web source in the background (`LookupSession.searchWeb`). `existing` is the word already saved in this category, if any.
    func start(_ rawTerm: String, from: AppLanguage, to: AppLanguage, existing: WordMO?) async -> LookupSession {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let dictionary = dictionaries.dictionary(for: from)
        var local: [LookupCandidate] = []
        var headword = term
        if settings.isEnabled(.localDictionary), let dictionary {
            let entries = dictionary.lookup(from.normalize(term))
            if !entries.isEmpty {
                local = await resolve(entries: entries, from: from, to: to, source: dictionary.id.sourceName)
                if !local.isEmpty { headword = entries[0].headword }
            }
        }
        let suggestions = local.isEmpty ? (dictionary?.suggestions(for: from.normalize(term)) ?? []) : []

        let webKinds = settings.ordered.filter { kind in
            switch kind {
            case .localDictionary: return false
            case .wiktionary: return from == .english
            case .appleTranslator: return translator.appleAvailable
            case .wikipedia, .myMemory: return true
            }
        }
        var hint: String?
        if local.isEmpty, !dictionaries.isInstalled(from.dictionary) {
            hint = "Install the \(from.dictionary.title) dictionary in Settings for instant offline meanings and similar words."
        } else if local.isEmpty, webKinds.isEmpty {
            hint = "No match found. Check the spelling, or turn on an online source in Settings → Dictionaries."
        }

        // The sheet starts the web search once it's on screen (LookupSheet), because Apple's translator
        // may need to show its own sheet, which would otherwise block the Add sheet from opening.
        return LookupSession(typed: term, existing: existing, headword: headword, local: local,
                             suggestions: suggestions, hint: hint, webKinds: webKinds) { [weak self] kind in
            await self?.webCandidates(kind, term: term, from: from, to: to) ?? []
        }
    }

    /// One web source's meanings for `term`; empty when it found nothing or failed.
    func webCandidates(_ kind: LookupSourceKind, term: String, from: AppLanguage, to: AppLanguage) async -> [LookupCandidate] {
        switch kind {
        case .localDictionary:
            return []

        case .wiktionary:
            guard from == .english,
                  let definitions = try? await WiktionaryClient().definitions(for: term),
                  !definitions.isEmpty else { return [] }
            let entry = DictEntry(headword: term, reading: "",
                                  senses: definitions.map { DictEntry.RawSense(pos: $0.pos, en: $0.english, zh: "") })
            return await resolve(entries: [entry], from: from, to: to, source: "Wiktionary")

        case .wikipedia:
            guard let summary = try? await WikipediaClient().summary(for: term, from: from, to: to) else { return [] }
            var sense = Sense(translation: "", english: from == .english ? summary.explanation : "")
            let sameName = summary.linkedTitle.map {
                $0.compare(summary.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            } ?? true
            if let linked = summary.linkedTitle, !sameName {
                sense.translation = linked
            } else if to == from {
                sense.translation = summary.explanation
            } else {
                // Kubernetes is Kubernetes in Chinese too, so its meaning comes from the description.
                let text = summary.shortDescription.isEmpty ? summary.explanation : summary.shortDescription
                if let output = await translator.translate([text], from: from, to: to), let first = output.first, !first.isEmpty {
                    sense.translation = first
                    sense.approximate = true
                } else {
                    sense.translation = summary.linkedTitle ?? summary.title
                }
            }
            return [LookupCandidate(sense: sense, reading: "", source: "Wikipedia")]

        case .appleTranslator:
            guard translator.appleAvailable, #available(iOS 18.0, macOS 15.0, *),
                  let output = try? await AppleTranslationBridge.shared.translate([term], from: from, to: to),
                  let text = output.first, !text.isEmpty, text.lowercased() != term.lowercased() else { return [] }
            let sense = Sense(translation: text, english: to == .english ? text : "")
            return [LookupCandidate(sense: sense, reading: "", source: "Apple Translate", machine: true)]

        case .myMemory:
            guard let results = try? await MyMemoryClient(email: settings.myMemoryEmail).translate(term, from: from, to: to) else { return [] }
            return results.map {
                LookupCandidate(sense: Sense(translation: $0, english: to == .english ? $0 : ""), reading: "",
                                source: "MyMemory", machine: true)
            }
        }
    }

    /// Turns dictionary senses into candidates in the pair's target language:
    /// * a Chinese target uses the dictionary's own Chinese when it has one (ECDICT),
    /// * an English target uses the English gloss (CC-CEDICT, JMdict),
    /// * anything else translates the English gloss and marks it approximate (JMdict → Chinese).
    private func resolve(entries: [DictEntry], from: AppLanguage, to: AppLanguage, source: String) async -> [LookupCandidate] {
        var candidates: [LookupCandidate] = []
        var needsTranslation: [Int] = []
        for entry in entries {
            for raw in entry.senses {
                var sense = Sense(translation: "", partOfSpeech: raw.pos, english: raw.en)
                if to == .chinese, !raw.zh.isEmpty {
                    sense.translation = raw.zh
                } else if to == .english {
                    sense.translation = raw.en
                } else {
                    needsTranslation.append(candidates.count)
                }
                candidates.append(LookupCandidate(sense: sense, reading: entry.reading, source: source))
            }
        }

        // Pivot through English for the senses that need it.
        let pending = needsTranslation.filter { !candidates[$0].sense.english.isEmpty }
        if !pending.isEmpty {
            // Translate only the first gloss of each sense: shorter text gives cleaner single-word results.
            let texts = pending.map { candidates[$0].sense.english.components(separatedBy: ",").first ?? "" }
            if let output = await translator.translate(texts, from: .english, to: to) {
                for (offset, index) in pending.enumerated() where offset < output.count {
                    candidates[index].sense.translation = output[offset]
                    candidates[index].sense.approximate = true
                }
            }
        }

        // Drop exact duplicates (same translation and part of speech).
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = candidate.sense.matchKey + "|" + candidate.sense.partOfSpeech + "|" + candidate.reading
            return seen.insert(key).inserted
        }
    }
}
