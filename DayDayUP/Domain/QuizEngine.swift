import Foundation

struct QuizQuestion: Identifiable {
    let id = UUID()
    let word: WordMO
    let prompt: String
    let options: [String]
    let correctIndex: Int
    /// Number of other saved meanings, shown after answering.
    let extraMeanings: Int
}

/// Builds quiz sessions with the rules agreed for DayDayUP:
/// * the answer is the word's primary sense (the first saved meaning),
/// * words are picked by priority, then shuffled,
/// * distractors share scope and part of speech, widening when there aren't enough.
@MainActor
enum QuizEngine {
    enum Length: Int, CaseIterable, Identifiable {
        case ten = 10, twenty = 20, fifty = 50, all = 0
        var id: Int { rawValue }
        var label: String { self == .all ? "All" : "\(rawValue)" }
    }

    /// Words due for review today (or overdue).
    static func dueToday(_ words: [WordMO]) -> [WordMO] {
        words.filter(\.isDue)
    }

    static func hasQuizzableMeaning(_ word: WordMO) -> Bool {
        word.primarySense.map { !$0.translation.isEmpty } ?? false
    }

    /// Priority for a list quiz: due reviews (Review Book, lowest step, most overdue) → words still
    /// climbing → New words (oldest first) → remembered words (only when included).
    static func pickWords(from pool: [WordMO], length: Length, includeRemembered: Bool) -> [WordMO] {
        let usable = pool.filter(hasQuizzableMeaning)
        let candidates = includeRemembered ? usable : usable.filter { !$0.isRemembered }

        let due = candidates.filter(\.isDue).sorted { ReviewSchedule.reviewPriority($0.schedule, $1.schedule) }
        let rest = candidates.filter { !$0.isDue }
        let climbing = rest.filter { !$0.isNew && !$0.isRemembered }.shuffled().sorted { $0.step < $1.step }
        let new = rest.filter(\.isNew).sorted { $0.addedDate < $1.addedDate }
        let remembered = rest.filter(\.isRemembered).shuffled()
        let ordered = due + climbing + new + remembered
        let count = length == .all ? ordered.count : min(length.rawValue, ordered.count)
        return Array(ordered.prefix(count)).shuffled()
    }

    /// - Parameters:
    ///   - scope: the words currently being studied (the filtered table).
    ///   - categoryWords: every live word in the same category, for the first widening step.
    ///   - dictionarySenses: random common dictionary senses in the target language, the last fallback.
    static func makeQuestion(for word: WordMO, scope: [WordMO], categoryWords: [WordMO],
                             dictionarySenses: [(pos: String, text: String)]) -> QuizQuestion? {
        guard let primary = word.primarySense, !primary.translation.isEmpty else { return nil }
        let answer = primary.translation
        let pos = primary.partOfSpeech
        var used: Set<String> = [normalize(answer)]
        var distractors: [String] = []

        func take(from options: [(pos: String, text: String)], samePOS: Bool) {
            for option in options.shuffled() where distractors.count < 3 {
                if samePOS && !pos.isEmpty && option.pos != pos { continue }
                if samePOS && pos.isEmpty && !option.pos.isEmpty { continue }
                let key = normalize(option.text)
                guard !option.text.isEmpty, !used.contains(key) else { continue }
                used.insert(key)
                distractors.append(option.text)
            }
        }

        func primaries(_ words: [WordMO]) -> [(pos: String, text: String)] {
            words.filter { $0.objectID != word.objectID }.compactMap { other in
                guard let sense = other.primarySense else { return nil }
                return (sense.partOfSpeech, sense.translation)
            }
        }

        let scopeOptions = primaries(scope)
        let categoryOptions = primaries(categoryWords)
        // 1. same scope + same part of speech, 2. same scope any POS,
        // 3. whole category same POS, 4. whole category any POS, 5. dictionary same POS, 6. dictionary any.
        take(from: scopeOptions, samePOS: true)
        if distractors.count < 3 { take(from: scopeOptions, samePOS: false) }
        if distractors.count < 3 { take(from: categoryOptions, samePOS: true) }
        if distractors.count < 3 { take(from: categoryOptions, samePOS: false) }
        if distractors.count < 3 { take(from: dictionarySenses, samePOS: true) }
        if distractors.count < 3 { take(from: dictionarySenses, samePOS: false) }

        guard !distractors.isEmpty else { return nil }
        var options = distractors + [answer]
        options.shuffle()
        return QuizQuestion(word: word, prompt: word.termValue, options: options,
                            correctIndex: options.firstIndex(of: answer) ?? 0,
                            extraMeanings: max(0, word.senses.count - 1))
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Random dictionary senses expressed in the pair's target language.
    static func dictionaryDistractors(for pair: LanguagePairMO, dictionaries: DictionaryManager) -> [(pos: String, text: String)] {
        switch pair.to {
        case .chinese:
            // ECDICT holds Chinese translations; use it for any pair that translates into Chinese.
            return (dictionaries.dictionary(.ecdict)?.randomSenses() ?? []).map { ($0.pos, $0.zh) }
        case .english:
            return (dictionaries.dictionary(for: pair.from)?.randomSenses() ?? []).map {
                ($0.pos, $0.en.components(separatedBy: ",").first ?? $0.en)
            }
        case .japanese:
            return []
        }
    }
}
