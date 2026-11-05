import Foundation

// MARK: - Source settings (Settings → Dictionary sources)

enum LookupSourceKind: String, Codable, CaseIterable, Identifiable {
    case localDictionary, wiktionary, appleTranslator, myMemory
    var id: String { rawValue }

    var title: String {
        switch self {
        case .localDictionary: return "Offline dictionaries"
        case .wiktionary: return "Wiktionary (English words)"
        case .appleTranslator: return "Apple Translate"
        case .myMemory: return "MyMemory"
        }
    }

    var detail: String {
        switch self {
        case .localDictionary: return "Instant and offline. Multiple meanings with parts of speech."
        case .wiktionary: return "Online English definitions when the offline dictionary has no entry."
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

enum LookupOutcome {
    /// One or more senses to pick from.
    case senses(term: String, candidates: [LookupCandidate])
    /// Nothing matched; these are the closest dictionary words.
    case suggestions(term: String, words: [String])
    /// Nothing matched and there were no suggestions.
    case nothing(term: String, message: String)
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

    /// Runs the configured sources in order; the first one that finds something wins.
    func lookup(_ rawTerm: String, from: AppLanguage, to: AppLanguage) async -> LookupOutcome {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .nothing(term: term, message: "Type a word first.") }

        for source in settings.ordered {
            switch source {
            case .localDictionary:
                guard let dictionary = dictionaries.dictionary(for: from) else { continue }
                let entries = dictionary.lookup(from.normalize(term))
                guard !entries.isEmpty else { continue }
                let candidates = await resolve(entries: entries, from: from, to: to, source: dictionary.id.sourceName)
                if !candidates.isEmpty { return .senses(term: entries[0].headword, candidates: candidates) }

            case .wiktionary:
                guard from == .english,
                      let definitions = try? await WiktionaryClient().definitions(for: term),
                      !definitions.isEmpty else { continue }
                let entry = DictEntry(headword: term, reading: "",
                                      senses: definitions.map { DictEntry.RawSense(pos: $0.pos, en: $0.english, zh: "") })
                let candidates = await resolve(entries: [entry], from: from, to: to, source: "Wiktionary")
                if !candidates.isEmpty { return .senses(term: term, candidates: candidates) }

            case .appleTranslator:
                guard translator.appleAvailable, #available(iOS 18.0, macOS 15.0, *),
                      let output = try? await AppleTranslationBridge.shared.translate([term], from: from, to: to),
                      let text = output.first, !text.isEmpty, text.lowercased() != term.lowercased() else { continue }
                let sense = Sense(translation: text, english: to == .english ? text : "")
                return .senses(term: term, candidates: [LookupCandidate(sense: sense, reading: "", source: "Apple Translate")])

            case .myMemory:
                guard let results = try? await MyMemoryClient(email: settings.myMemoryEmail).translate(term, from: from, to: to),
                      !results.isEmpty else { continue }
                let candidates = results.map {
                    LookupCandidate(sense: Sense(translation: $0, english: to == .english ? $0 : ""), reading: "", source: "MyMemory")
                }
                return .senses(term: term, candidates: candidates)
            }
        }

        if let dictionary = dictionaries.dictionary(for: from) {
            let words = dictionary.suggestions(for: from.normalize(term))
            if !words.isEmpty { return .suggestions(term: term, words: words) }
        }
        let hint = dictionaries.isInstalled(from.dictionary)
            ? "No match found. Check the spelling or add the meaning yourself."
            : "No match found. Install the \(from.dictionary.title) dictionary in Settings for offline lookups and suggestions."
        return .nothing(term: term, message: hint)
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
