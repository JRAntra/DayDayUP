import SwiftUI

/// The languages DayDayUP knows how to look up, translate and speak.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case chinese = "zh"
    case japanese = "ja"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        }
    }

    /// A compact glyph used on pair badges.
    var badge: String {
        switch self {
        case .english: return "EN"
        case .chinese: return "中"
        case .japanese: return "日"
        }
    }

    /// BCP-47 code used for text-to-speech voices.
    var speechCode: String {
        switch self {
        case .english: return "en-US"
        case .chinese: return "zh-CN"   // Simplified Chinese, mainland Mandarin
        case .japanese: return "ja-JP"
        }
    }

    /// Language code used by the MyMemory API.
    var myMemoryCode: String {
        switch self {
        case .english: return "en"
        case .chinese: return "zh-CN"
        case .japanese: return "ja"
        }
    }

    /// Identifier used by Apple's Translation framework.
    var translationIdentifier: String {
        switch self {
        case .english: return "en"
        case .chinese: return "zh-Hans"
        case .japanese: return "ja"
        }
    }

    /// The offline dictionary that covers this language as a *source* language.
    var dictionary: DictionaryID {
        switch self {
        case .english: return .ecdict
        case .chinese: return .cedict
        case .japanese: return .jmdict
        }
    }

    /// Lookup keys are lower-cased for English; CJK stays as typed.
    func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return self == .english ? trimmed.lowercased() : trimmed
    }
}

enum ChineseScript: String, Codable, CaseIterable {
    case simplified, traditional   // Traditional is reserved for later; Simplified is the default.
}

/// Offline dictionaries built by Tools/build_dictionaries.py.
enum DictionaryID: String, CaseIterable, Identifiable, Codable {
    case ecdict, cedict, jmdict

    var id: String { rawValue }
    var fileName: String { "\(rawValue).sqlite" }

    var title: String {
        switch self {
        case .ecdict: return "English → Chinese"
        case .cedict: return "Chinese → English"
        case .jmdict: return "Japanese → English"
        }
    }

    var sourceName: String {
        switch self {
        case .ecdict: return "ECDICT"
        case .cedict: return "CC-CEDICT"
        case .jmdict: return "JMdict"
        }
    }

    /// The official download, built into the app. The file is converted on the device after it arrives.
    var sourceURL: URL {
        switch self {
        case .ecdict: return URL(string: "https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv")!
        case .cedict: return URL(string: "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz")!
        case .jmdict: return URL(string: "https://www.edrdg.org/pub/Nihongo/JMdict_e.gz")!
        }
    }

    /// Size of the file once saved, used for the progress bar when the server compresses the transfer
    /// and doesn't send a length (GitHub does this for ecdict.csv).
    var expectedBytes: Int64 {
        switch self {
        case .ecdict: return 66_009_548
        case .cedict: return 3_983_413
        case .jmdict: return 10_593_448
        }
    }

    /// Approximate download size, shown before the person taps Download.
    var downloadSize: String {
        switch self {
        case .ecdict: return "66 MB"
        case .cedict: return "4 MB"
        case .jmdict: return "11 MB"
        }
    }

    var license: String {
        switch self {
        case .ecdict: return "ECDICT by skywind3000, MIT License."
        case .cedict: return "CC-CEDICT by MDBG, Creative Commons Attribution-ShareAlike 3.0."
        case .jmdict: return "JMdict by the Electronic Dictionary Research and Development Group, CC BY-SA 4.0."
        }
    }
}

/// Bright, playful accents. Each language pair is given one when created.
enum PairPalette {
    static let hexes = ["1FA2FF", "E85D9A", "FF8A3D", "7B5CFF", "14B8A6", "84CC16"]

    static func next(after used: [String]) -> String {
        hexes.first { !used.contains($0) } ?? hexes[used.count % hexes.count]
    }
}
