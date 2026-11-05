import AVFoundation
import CryptoKit
import Security
import SwiftUI

/// Pronunciation, most human first:
///
/// 1. **Real recordings** of native speakers (Wiktionary, files on Wikimedia Commons), English only,
///    preferring the chosen accent (US or UK).
/// 2. **Azure neural voices**: textbook-standard en-US / en-GB, Mandarin and Japanese voices.
///    Needs your own Azure Speech key and region (Settings → Pronunciation); the free tier is plenty.
///    Chinese words are sent with their dictionary pinyin so polyphones such as 行 (xíng / háng)
///    are read the right way; Japanese words are spoken from their kana reading.
/// 3. **Apple's built-in voice**, offline, when neither of the above is available.
///
/// Downloaded audio is cached on disk, so each word is fetched once.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    enum Source: String {
        case recording, neural, device

        var label: String {
            switch self {
            case .recording: return "Human recording"
            case .neural: return "Azure neural voice"
            case .device: return "Apple voice (offline)"
            }
        }
    }

    enum EnglishAccent: String, CaseIterable, Identifiable {
        case us, uk
        var id: String { rawValue }
        var label: String { self == .us ? "American (US)" : "British (UK)" }
        var locale: String { self == .us ? "en-US" : "en-GB" }
    }

    struct NeuralVoice: Identifiable, Hashable {
        let id: String      // Azure short name, e.g. en-US-JennyNeural
        let label: String
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var currentTask: Task<Void, Never>?

    @Published var rate: Float { didSet { UserDefaults.standard.set(rate, forKey: "speech.rate") } }
    @Published var autoPlayFlashcards: Bool { didSet { UserDefaults.standard.set(autoPlayFlashcards, forKey: "speech.autoFlash") } }
    @Published var speakInQuiz: Bool { didSet { UserDefaults.standard.set(speakInQuiz, forKey: "speech.quiz") } }
    /// The single "Speak words aloud" switch in the Study sheet and on Today: speaks each quiz word and
    /// plays each flashcard as it appears.
    var speakAloud: Bool {
        get { autoPlayFlashcards }
        set { speakInQuiz = newValue; autoPlayFlashcards = newValue }
    }
    @Published private var voiceIDs: [String: String] {
        didSet { UserDefaults.standard.set(voiceIDs, forKey: "speech.voices") }
    }

    @Published var useRecordings: Bool { didSet { UserDefaults.standard.set(useRecordings, forKey: "speech.recordings") } }
    @Published var englishAccent: EnglishAccent {
        didSet { UserDefaults.standard.set(englishAccent.rawValue, forKey: "speech.accent") }
    }
    @Published var azureRegion: String {
        didSet { UserDefaults.standard.set(azureRegion.trimmingCharacters(in: .whitespaces), forKey: "speech.azureRegion") }
    }
    @Published var azureKey: String {
        didSet { Keychain.set(azureKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.azureKeyAccount) }
    }
    @Published private var neuralVoiceIDs: [String: String] {
        didSet { UserDefaults.standard.set(neuralVoiceIDs, forKey: "speech.neuralVoices") }
    }

    /// Where the last word's audio came from, shown in Settings.
    @Published private(set) var lastSource: Source?
    /// Why the natural voice wasn't used last time (for example a wrong key), shown in Settings.
    @Published private(set) var lastProblem: String?

    private static let azureKeyAccount = "azure.speech.key"

    override init() {
        let defaults = UserDefaults.standard
        rate = defaults.object(forKey: "speech.rate") as? Float ?? 0.5
        let flashcards = defaults.object(forKey: "speech.autoFlash") as? Bool ?? true
        autoPlayFlashcards = flashcards
        // The two switches became one ("Speak words aloud"); start it from the flashcard setting.
        if defaults.bool(forKey: "speech.unifiedSpeakAloud") {
            speakInQuiz = defaults.object(forKey: "speech.quiz") as? Bool ?? flashcards
        } else {
            speakInQuiz = flashcards
            defaults.set(flashcards, forKey: "speech.quiz")   // didSet doesn't run during init
            defaults.set(true, forKey: "speech.unifiedSpeakAloud")
        }
        voiceIDs = defaults.dictionary(forKey: "speech.voices") as? [String: String] ?? [:]
        useRecordings = defaults.object(forKey: "speech.recordings") as? Bool ?? true
        englishAccent = EnglishAccent(rawValue: defaults.string(forKey: "speech.accent") ?? "") ?? .us
        azureRegion = defaults.string(forKey: "speech.azureRegion") ?? ""
        azureKey = Keychain.get(Self.azureKeyAccount) ?? ""
        neuralVoiceIDs = defaults.dictionary(forKey: "speech.neuralVoices") as? [String: String] ?? [:]
        super.init()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        #endif
    }

    // MARK: Speaking

    func speak(_ term: String, reading: String? = nil, language: AppLanguage) {
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        currentTask = Task { [weak self] in
            guard let self else { return }
            if let (data, source) = await self.naturalAudio(for: text, reading: reading, language: language),
               !Task.isCancelled, self.play(data) {
                self.lastSource = source
                return
            }
            guard !Task.isCancelled else { return }
            self.speakOnDevice(text, reading: reading, language: language)
            self.lastSource = .device
        }
    }

    func speak(_ word: WordMO) {
        speak(word.termValue, reading: word.reading, language: word.pair?.from ?? .english)
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        player?.stop()
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func play(_ data: Data) -> Bool {
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        player.enableRate = true
        // The speed slider's middle (0.5) is normal speed for recordings too.
        player.rate = max(0.5, min(2, rate * 2))
        player.prepareToPlay()
        self.player = player
        return player.play()
    }

    private func speakOnDevice(_ term: String, reading: String?, language: AppLanguage) {
        var text = term
        if language == .japanese, let reading, !reading.isEmpty, !reading.hasPrefix("/") {
            text = reading
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: language)
        utterance.rate = rate
        synthesizer.speak(utterance)
    }

    // MARK: Natural audio (recordings, then Azure)

    private func naturalAudio(for term: String, reading: String?, language: AppLanguage) async -> (Data, Source)? {
        if language == .english, useRecordings, let data = await recording(for: term) {
            return (data, .recording)
        }
        if let data = await neural(for: term, reading: reading, language: language) {
            return (data, .neural)
        }
        return nil
    }

    var isNeuralConfigured: Bool {
        !azureKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !azureRegion.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A native-speaker recording from Wiktionary (files on Wikimedia Commons, CC BY-SA),
    /// chosen accent first, fetched as Commons' MP3 copy because Apple can't play Ogg.
    func recording(for term: String) async -> Data? {
        let key = "rec-\(englishAccent.rawValue)-\(term.lowercased())"
        if let cached = AudioCache.data(for: key) { return cached }
        if AudioCache.isKnownMissing(key) { return nil }

        var titles = [term]
        if term.lowercased() != term { titles.append(term.lowercased()) }
        var files: [String] = []
        var reachedServer = false
        for title in titles {
            guard let found = await wiktionaryAudioFiles(title) else { continue }
            reachedServer = true
            files = found
            if !files.isEmpty { break }
        }
        guard reachedServer else { return nil }      // offline: try again next time

        for file in Self.rankRecordings(files, word: term, accent: englishAccent).prefix(3) {
            if let audio = await commonsMP3(file), (try? AVAudioPlayer(data: audio)) != nil {
                AudioCache.store(audio, for: key)
                return audio
            }
        }
        AudioCache.markMissing(key)
        return nil
    }

    private static let wikimediaUserAgent = "DayDayUP/1.0 (personal vocabulary app)"

    private func wikimediaJSON(_ host: String, _ query: [URLQueryItem]) async -> [String: Any]? {
        var components = URLComponents(string: "https://\(host)/w/api.php")!
        components.queryItems = query + [URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue(Self.wikimediaUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Audio files used on the word's English Wiktionary page, e.g. "File:En-us-apple.ogg".
    private func wiktionaryAudioFiles(_ title: String) async -> [String]? {
        guard let json = await wikimediaJSON("en.wiktionary.org", [
            .init(name: "action", value: "query"), .init(name: "titles", value: title),
            .init(name: "prop", value: "images"), .init(name: "imlimit", value: "100"),
            .init(name: "redirects", value: "1")]),
              let pages = (json["query"] as? [String: Any])?["pages"] as? [String: Any] else { return nil }
        let audioExtensions = [".ogg", ".oga", ".wav", ".mp3", ".flac", ".opus"]
        return pages.values.compactMap { $0 as? [String: Any] }
            .flatMap { ($0["images"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["title"] as? String }
            .filter { name in audioExtensions.contains { name.lowercased().hasSuffix($0) } }
    }

    /// English recordings only, the chosen accent first, files named after this exact word first.
    static func rankRecordings(_ files: [String], word: String, accent: EnglishAccent) -> [String] {
        let w = word.lowercased().replacingOccurrences(of: " ", with: "_")
        func score(_ file: String) -> Int? {
            let name = file.lowercased().replacingOccurrences(of: "file:", with: "").replacingOccurrences(of: " ", with: "_")
            let preferred = accent == .us ? ["en-us-"] : ["en-uk-", "en-gb-"]
            var s: Int
            if preferred.contains(where: name.hasPrefix) { s = 0 }
            else if name.hasPrefix("en-us-") || name.hasPrefix("en-uk-") || name.hasPrefix("en-gb-") { s = 10 }
            else if name.hasPrefix("en-") { s = 20 }
            else if name.hasPrefix("ll-q1860_(eng)") { s = 30 }   // Lingua Libre, English, accent unknown
            else { return nil }                                   // another language's recording
            let stem = name.split(separator: ".").dropLast().joined(separator: ".")
            if !(stem.hasSuffix("-" + w) || stem == w) { s += 5 }  // e.g. a plural or a phrase on the same page
            return s
        }
        return files.compactMap { f in score(f).map { (f, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// The MP3 copy Wikimedia Commons keeps of a recording.
    private func commonsMP3(_ file: String) async -> Data? {
        guard let json = await wikimediaJSON("commons.wikimedia.org", [
            .init(name: "action", value: "query"), .init(name: "titles", value: file),
            .init(name: "prop", value: "videoinfo"), .init(name: "viprop", value: "derivatives|url")]),
              let pages = (json["query"] as? [String: Any])?["pages"] as? [String: Any],
              let info = (pages.values.first as? [String: Any])?["videoinfo"] as? [[String: Any]],
              let first = info.first else { return nil }
        let derivatives = (first["derivatives"] as? [[String: Any]]) ?? []
        var source = derivatives.first { ($0["type"] as? String)?.hasPrefix("audio/mpeg") == true }?["src"] as? String
        if source == nil, let original = first["url"] as? String, original.lowercased().contains(".mp3") { source = original }
        guard let source, let url = URL(string: source) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(Self.wikimediaUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (audio, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !audio.isEmpty else { return nil }
        return audio
    }

    /// Azure neural text-to-speech (REST, mp3), cached per voice and text.
    private func neural(for term: String, reading: String?, language: AppLanguage) async -> Data? {
        guard isNeuralConfigured else { return nil }
        let voice = neuralVoice(for: language)
        let locale = String(voice.id.split(separator: "-").prefix(2).joined(separator: "-"))
        var spoken = Self.xmlEscape(term)
        var phonemeSSML: String?
        switch language {
        case .japanese:
            if let reading, !reading.isEmpty, !reading.hasPrefix("/") { spoken = Self.xmlEscape(reading) }
        case .chinese:
            if let reading, let ph = Self.sapiPinyin(reading, matching: term) {
                phonemeSSML = "<phoneme alphabet=\"sapi\" ph=\"\(Self.xmlEscape(ph))\">\(spoken)</phoneme>"
            }
        case .english:
            break
        }

        let key = "tts-\(voice.id)-\(phonemeSSML ?? spoken)"
        if let cached = AudioCache.data(for: key) { return cached }

        if let phonemeSSML, let data = await azureRequest(ssmlBody: phonemeSSML, voice: voice.id, locale: locale) {
            AudioCache.store(data, for: key)
            return data
        }
        // Without a pinyin hint (or when Azure rejected it).
        guard let data = await azureRequest(ssmlBody: spoken, voice: voice.id, locale: locale) else { return nil }
        AudioCache.store(data, for: key)
        return data
    }

    private func azureRequest(ssmlBody: String, voice: String, locale: String) async -> Data? {
        let region = azureRegion.trimmingCharacters(in: .whitespaces).lowercased()
        guard let url = URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1") else {
            lastProblem = "The Azure region doesn't look right. Use the short name, for example eastus."
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue(azureKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("DayDayUP", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("""
            <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="\(locale)">\
            <voice name="\(voice)">\(ssmlBody)</voice></speak>
            """.utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200 where !data.isEmpty:
                lastProblem = nil
                return data
            case 401, 403:
                lastProblem = "Azure refused the key (\(status)). Check the key and that the region matches your Speech resource."
            case 429:
                lastProblem = "Azure's free quota or rate limit was reached. Using Apple's voice for now."
            case 400:
                break   // usually an unsupported pinyin hint; the caller retries without it
            default:
                lastProblem = "Azure answered \(status). Using Apple's voice for now."
            }
        } catch {
            lastProblem = "Couldn't reach Azure (\(error.localizedDescription)). Using Apple's voice."
        }
        return nil
    }

    // MARK: Neural voice choices

    static func neuralVoices(for language: AppLanguage, accent: EnglishAccent) -> [NeuralVoice] {
        switch language {
        case .english where accent == .us:
            return [.init(id: "en-US-JennyNeural", label: "Jenny · female"),
                    .init(id: "en-US-AriaNeural", label: "Aria · female"),
                    .init(id: "en-US-GuyNeural", label: "Guy · male"),
                    .init(id: "en-US-AndrewNeural", label: "Andrew · male")]
        case .english:
            return [.init(id: "en-GB-SoniaNeural", label: "Sonia · female"),
                    .init(id: "en-GB-LibbyNeural", label: "Libby · female"),
                    .init(id: "en-GB-RyanNeural", label: "Ryan · male")]
        case .chinese:
            return [.init(id: "zh-CN-XiaoxiaoNeural", label: "Xiaoxiao 晓晓 · female"),
                    .init(id: "zh-CN-XiaoyiNeural", label: "Xiaoyi 晓伊 · female"),
                    .init(id: "zh-CN-YunxiNeural", label: "Yunxi 云希 · male"),
                    .init(id: "zh-CN-YunjianNeural", label: "Yunjian 云健 · male")]
        case .japanese:
            return [.init(id: "ja-JP-NanamiNeural", label: "Nanami 七海 · female"),
                    .init(id: "ja-JP-AoiNeural", label: "Aoi 碧衣 · female"),
                    .init(id: "ja-JP-KeitaNeural", label: "Keita 圭太 · male")]
        }
    }

    private func neuralKey(_ language: AppLanguage) -> String {
        language == .english ? "en-\(englishAccent.rawValue)" : language.rawValue
    }

    func neuralVoice(for language: AppLanguage) -> NeuralVoice {
        let options = Self.neuralVoices(for: language, accent: englishAccent)
        let chosen = neuralVoiceIDs[neuralKey(language)]
        return options.first { $0.id == chosen } ?? options[0]
    }

    func setNeuralVoice(_ id: String, for language: AppLanguage) {
        neuralVoiceIDs[neuralKey(language)] = id
    }

    func clearAudioCache() { AudioCache.clear() }
    var audioCacheSize: Int { AudioCache.size() }

    // MARK: Apple voices (offline fallback)

    /// Voices for a language, best quality first. English includes US, UK, Australian and other accents.
    func voices(for language: AppLanguage) -> [AVSpeechSynthesisVoice] {
        let prefix: String
        switch language {
        case .english: prefix = "en"
        case .chinese: prefix = "zh-CN"
        case .japanese: prefix = "ja"
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    func selectedVoiceID(for language: AppLanguage) -> String? { voiceIDs[language.rawValue] }

    func setVoice(_ id: String?, for language: AppLanguage) {
        voiceIDs[language.rawValue] = id
    }

    private func voice(for language: AppLanguage) -> AVSpeechSynthesisVoice? {
        if let id = voiceIDs[language.rawValue], let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        if language == .english {
            // Best installed voice in the chosen accent.
            if let match = voices(for: .english).first(where: { $0.language == englishAccent.locale }) { return match }
        }
        return voices(for: language).first ?? AVSpeechSynthesisVoice(language: language.speechCode)
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .enhanced: return "Enhanced"
        case .default: return "Standard"
        default: return voice.quality.rawValue >= 3 ? "Premium" : "Standard"
        }
    }

    // MARK: Helpers

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let toneVowels: [Character: (Character, Int)] = {
        var map: [Character: (Character, Int)] = [:]
        for (base, marks) in [("a", "āáǎà"), ("e", "ēéěè"), ("i", "īíǐì"), ("o", "ōóǒò"), ("u", "ūúǔù"), ("v", "ǖǘǚǜ")] {
            for (i, m) in marks.enumerated() { map[m] = (Character(base), i + 1) }
        }
        return map
    }()

    /// "xué xí" → "xue 2 xi 2" (Azure's zh-CN SAPI phones), only when there is one syllable per character.
    static func sapiPinyin(_ reading: String, matching term: String) -> String? {
        let hanCount = term.unicodeScalars.filter { $0.properties.isIdeographic }.count
        let syllables = reading.lowercased().split(whereSeparator: { $0 == " " || $0 == "·" || $0 == "'" })
        guard hanCount > 0, syllables.count == hanCount, hanCount == term.count else { return nil }
        var parts: [String] = []
        for syllable in syllables {
            var tone = 5
            var plain = ""
            for ch in syllable {
                if let (base, t) = toneVowels[ch] { plain.append(base); tone = t }
                else if ch == "ü" { plain.append("v") }
                else if ch.isLetter, ch.isASCII { plain.append(ch) }
                else { return nil }
            }
            guard !plain.isEmpty else { return nil }
            parts.append("\(plain) \(tone)")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Audio cache

/// Small on-disk cache of pronunciation audio under Application Support.
enum AudioCache {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("VocaQuest/Pronunciation", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ key: String, ext: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest + "." + ext)
    }

    static func data(for key: String) -> Data? { try? Data(contentsOf: file(key, ext: "mp3")) }
    static func store(_ data: Data, for key: String) { try? data.write(to: file(key, ext: "mp3"), options: .atomic) }

    /// Words with no recording are remembered for a week so they aren't looked up every time.
    static func isKnownMissing(_ key: String) -> Bool {
        let url = file(key, ext: "missing")
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
        return Date().timeIntervalSince(date) < 7 * 24 * 3600
    }

    static func markMissing(_ key: String) { try? Data().write(to: file(key, ext: "missing")) }

    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func size() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

// MARK: - Keychain

/// Stores the Azure key in the Keychain rather than in preferences.
enum Keychain {
    private static let service = "DayDayUP"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
