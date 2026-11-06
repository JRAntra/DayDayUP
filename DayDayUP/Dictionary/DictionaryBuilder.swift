import Foundation
import SQLite3

/// Turns the raw files people download into the app's offline dictionary format, on the device.
///
/// Accepts (optionally .gz-compressed):
/// * `ecdict.csv` from https://github.com/skywind3000/ECDICT
/// * `cedict_1_0_ts_utf-8_mdbg.txt` from MDBG (CC-CEDICT)
/// * `JMdict_e` from EDRDG
/// * a `.sqlite` already built by Tools/build_dictionaries.py
///
/// The rules mirror Tools/build_dictionaries.py exactly, so a file built here matches one built there.
enum DictionaryBuilder {
    /// Untagged ECDICT phrases are kept only up to this frequency rank (same default as the script).
    /// Single words are always kept. Words above this rank also count as rare in similar-word suggestions.
    static let ecdictMaxRank = 60000
    /// Version of the ECDICT file layout. 2 keeps every single word and adds the `sounds` table;
    /// an installed file with a lower number shows "Update" in Settings.
    static let ecdictFormat = 2

    enum SourceKind { case sqlite, ecdict, cedict, jmdict }

    struct Result: Sendable {
        let id: DictionaryID
        let sqliteURL: URL
    }

    enum ImportError: LocalizedError {
        case zipArchive
        case unrecognized
        case corruptArchive
        case noEntries

        var errorDescription: String? {
            switch self {
            case .zipArchive:
                return "This is a .zip archive. Unzip it first, then import the file inside (for example ecdict.csv)."
            case .unrecognized:
                return "This isn't a dictionary file DayDayUP knows. Import ecdict.csv (GitHub · ECDICT), the CC-CEDICT .txt or .txt.gz (MDBG), JMdict_e or JMdict_e.gz (EDRDG), or a built .sqlite."
            case .corruptArchive:
                return "This .gz file couldn't be decompressed. Download it again and retry."
            case .noEntries:
                return "No dictionary entries were found in this file."
            }
        }
    }

    /// Builds (or just unpacks) `source` into a .sqlite inside `workDir`.
    /// `progress` receives the dictionary being built and a 0…1 fraction.
    static func prepare(_ source: URL, requested: DictionaryID, workDir: URL,
                        progress: @escaping @Sendable (DictionaryID, Double) -> Void) throws -> Result {
        var data = try Data(contentsOf: source, options: .mappedIfSafe)
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { throw ImportError.zipArchive }
        var unpacked = false
        if data.starts(with: [0x1F, 0x8B]) {
            data = try gunzip(data)
            unpacked = true
        }
        guard let kind = sniff(data) else { throw ImportError.unrecognized }

        let id: DictionaryID
        switch kind {
        case .sqlite:
            // A prebuilt file: install it for the row the person picked it from.
            progress(requested, 1)
            if !unpacked { return Result(id: requested, sqliteURL: source) }
            let out = workDir.appendingPathComponent(UUID().uuidString + ".sqlite")
            try data.write(to: out)
            return Result(id: requested, sqliteURL: out)
        case .ecdict: id = .ecdict
        case .cedict: id = .cedict
        case .jmdict: id = .jmdict
        }

        progress(id, 0)
        let out = workDir.appendingPathComponent(UUID().uuidString + ".sqlite")
        let report: (Double) -> Void = { progress(id, $0) }
        let count: Int
        switch kind {
        case .ecdict: count = try buildECDICT(data, to: out, progress: report)
        case .cedict: count = try buildCEDICT(data, to: out, progress: report)
        case .jmdict: count = try buildJMdict(data, to: out, progress: report)
        case .sqlite: count = 0
        }
        guard count > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw ImportError.noEntries
        }
        return Result(id: id, sqliteURL: out)
    }

    // MARK: - Detecting the file

    static func sniff(_ data: Data) -> SourceKind? {
        if data.starts(with: Array("SQLite format 3".utf8)) { return .sqlite }
        var head = String(decoding: data.prefix(8192), as: UTF8.self)
        if head.hasPrefix("\u{FEFF}") { head.removeFirst() }
        let firstLine = head.prefix { !$0.isNewline }.lowercased()
        if firstLine.hasPrefix("word,") && firstLine.contains("translation") { return .ecdict }
        if head.contains("<JMdict") || head.contains("<!DOCTYPE JMdict") { return .jmdict }
        if head.contains("CC-CEDICT") { return .cedict }
        // A CC-CEDICT file without its comment header: look for "trad simp [pin1 yin1] /gloss/".
        for line in head.split(whereSeparator: \.isNewline).prefix(20) where parseCEDICTLine(String(line)) != nil {
            return .cedict
        }
        return nil
    }

    // MARK: - gzip

    /// Strips the gzip wrapper and inflates the raw DEFLATE stream with Apple's Compression framework.
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw ImportError.corruptArchive }
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0 {                       // FEXTRA
            guard i + 2 <= bytes.count else { throw ImportError.corruptArchive }
            i += 2 + (Int(bytes[i]) | Int(bytes[i + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {   // FNAME, FCOMMENT (zero-terminated)
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }              // FHCRC
        guard i < bytes.count - 8 else { throw ImportError.corruptArchive }
        let deflate = Data(bytes[i..<(bytes.count - 8)])
        do {
            return try (deflate as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw ImportError.corruptArchive
        }
    }

    // MARK: - Shared text rules (same as the Python script)

    private static let stripSet: Set<Character> = [" ", ",", "，"]

    /// Sense fields must never contain ';' because the app's CSV export joins senses with '; '.
    static func clean(_ text: String) -> String {
        let replaced = text.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "；", with: "，")
        let collapsed = replaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var s = Substring(collapsed)
        while let f = s.first, stripSet.contains(f) { s.removeFirst() }
        while let l = s.last, stripSet.contains(l) { s.removeLast() }
        return String(s)
    }

    struct OutSense {
        var pos: String
        var en: String
        var zh: String
    }

    // MARK: - ECDICT

    /// `^\s*([a-z]{1,6}\.)\s*(.*)$` → (pos, rest), or ("", line) when there is no part of speech.
    static func splitPOS(_ line: String) -> (String, String) {
        let scalars = Array(line.unicodeScalars)
        var i = 0
        while i < scalars.count, i <= 6, scalars[i].value >= 0x61, scalars[i].value <= 0x7A { i += 1 }
        guard i >= 1, i <= 6, i < scalars.count, scalars[i] == "." else { return ("", line) }
        var pos = String.UnicodeScalarView()
        pos.append(contentsOf: scalars[0...i])
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: scalars[(i + 1)...])
        return (String(pos), String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func splitPOSLines(_ field: String) -> [(String, String)] {
        field.replacingOccurrences(of: "\\n", with: "\n")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(splitPOS)
    }

    static func buildECDICT(_ data: Data, to out: URL, progress: (Double) -> Void) throws -> Int {
        let writer = try DictionaryWriter(path: out.path,
                                          meta: ["id": "ecdict", "source": "en", "title": "ECDICT", "license": "MIT",
                                                 "format": String(ecdictFormat)],
                                          soundKeys: true)
        var columns: [String: Int] = [:]
        var isHeader = true

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let total = bytes.count
            var rowBuffer: [UInt8] = []
            rowBuffer.reserveCapacity(64 * 1024)
            var fields: [Range<Int>] = []
            var fieldStart = 0
            var inQuotes = false
            var i = 0
            var nextReport = 0
            // Skip a UTF-8 byte-order mark.
            if total >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }

            func endField() {
                fields.append(fieldStart..<rowBuffer.count)
                fieldStart = rowBuffer.count
            }

            func endRow() throws {
                endField()
                defer {
                    rowBuffer.removeAll(keepingCapacity: true)
                    fields.removeAll(keepingCapacity: true)
                    fieldStart = 0
                }
                if fields.count == 1 && fields[0].isEmpty { return }
                if isHeader {
                    isHeader = false
                    for (index, range) in fields.enumerated() {
                        let name = String(decoding: rowBuffer[range], as: UTF8.self)
                            .trimmingCharacters(in: .whitespaces).lowercased()
                        columns[name] = index
                    }
                    return
                }
                try rowBuffer.withUnsafeBufferPointer { buffer in
                    try handleECDICTRow(buffer, fields: fields, columns: columns, writer: writer)
                }
            }

            while i < total {
                let b = bytes[i]
                if inQuotes {
                    if b == 0x22 {                               // "
                        if i + 1 < total, bytes[i + 1] == 0x22 { rowBuffer.append(0x22); i += 1 } else { inQuotes = false }
                    } else {
                        rowBuffer.append(b)
                    }
                } else {
                    switch b {
                    case 0x22: inQuotes = true
                    case 0x2C: endField()                       // ,
                    case 0x0A: try endRow()                     // \n
                    case 0x0D:                                  // \r or \r\n
                        if i + 1 < total, bytes[i + 1] == 0x0A { i += 1 }
                        try endRow()
                    default: rowBuffer.append(b)
                    }
                }
                i += 1
                if i >= nextReport {
                    progress(Double(i) / Double(max(total, 1)) * 0.95)
                    nextReport = i + max(total / 100, 1)
                }
            }
            if !rowBuffer.isEmpty || !fields.isEmpty { try endRow() }
        }
        progress(0.97)
        return try writer.finish()
    }

    private static func handleECDICTRow(_ row: UnsafeBufferPointer<UInt8>, fields: [Range<Int>],
                                        columns: [String: Int], writer: DictionaryWriter) throws {
        func range(_ name: String) -> Range<Int>? {
            guard let index = columns[name], index < fields.count else { return nil }
            return fields[index]
        }
        func isBlank(_ r: Range<Int>?) -> Bool {
            guard let r else { return true }
            return r.allSatisfy { row[$0] == 0x20 || row[$0] == 0x09 || row[$0] == 0x0A || row[$0] == 0x0D }
        }
        func equals(_ r: Range<Int>?, _ text: String) -> Bool {
            let target = Array(text.utf8)
            guard let r else { return target.isEmpty }
            return r.count == target.count && zip(r, target).allSatisfy { row[$0] == $1 }
        }
        func number(_ r: Range<Int>?) -> Int? {
            guard let r else { return nil }
            var value = 0
            var digits = 0
            for index in r {
                let c = row[index]
                if c == 0x20 || c == 0x09 { continue }
                guard c >= 0x30, c <= 0x39 else { return nil }
                value = value * 10 + Int(c - 0x30)
                digits += 1
                if digits > 9 { return nil }
            }
            return digits > 0 && value > 0 ? value : nil
        }
        func text(_ r: Range<Int>?) -> String {
            guard let r else { return "" }
            return String(decoding: UnsafeBufferPointer(rebasing: row[r]), as: UTF8.self)
        }

        // keep_ecdict_row
        guard let wordRange = range("word"), !wordRange.isEmpty else { return }
        let scalarCount = wordRange.reduce(0) { $0 + ((row[$1] & 0xC0) == 0x80 ? 0 : 1) }
        guard scalarCount <= 40, !isBlank(range("translation")) else { return }
        let rank = [number(range("frq")), number(range("bnc"))].compactMap { $0 }.min() ?? 999_999
        let collinsRange = range("collins")
        let tagged = !isBlank(range("tag")) || equals(range("oxford"), "1")
            || !(equals(collinsRange, "") || equals(collinsRange, "0"))
        let word = text(wordRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tagged || rank <= ecdictMaxRank || SoundKey.isSingleWord(word) else { return }

        var definitions = splitPOSLines(text(range("definition")))
        var senses: [OutSense] = []
        for (pos, zhLine) in splitPOSLines(text(range("translation"))) {
            // Pair each Chinese line with the first unused English definition of the same POS.
            var en = ""
            if let index = definitions.firstIndex(where: { $0.0 == pos }) {
                en = definitions[index].1
                definitions.remove(at: index)
            }
            let cleanEnglish = clean(en)
            for zh in zhLine.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ";" || $0 == "；" }) {
                let z = clean(String(zh))
                if !z.isEmpty { senses.append(OutSense(pos: pos, en: cleanEnglish, zh: z)) }
            }
        }
        guard !senses.isEmpty else { return }
        let phonetic = text(range("phonetic")).trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.add(headword: word, reading: phonetic.isEmpty ? "" : "/\(phonetic)/",
                       senses: senses, rank: rank, forms: [word.lowercased()])
    }

    // MARK: - CC-CEDICT

    /// `^(\S+)\s+(\S+)\s+\[([^\]]*)\]\s+/(.*)/\s*$` → (traditional, simplified, pinyin, glosses)
    static func parseCEDICTLine(_ raw: String) -> (String, String, String, String)? {
        let line = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        func token(_ s: Substring) -> (Substring, Substring)? {
            guard let end = s.firstIndex(where: \.isWhitespace) else { return nil }
            let rest = s[end...].drop(while: \.isWhitespace)
            return s.startIndex < end ? (s[s.startIndex..<end], rest) : nil
        }
        guard let (trad, afterTrad) = token(line), let (simp, afterSimp) = token(afterTrad),
              afterSimp.first == "[", let close = afterSimp.firstIndex(of: "]") else { return nil }
        let pinyin = afterSimp[afterSimp.index(after: afterSimp.startIndex)..<close]
        let afterBracket = afterSimp[afterSimp.index(after: close)...]
        guard let firstAfter = afterBracket.first, firstAfter.isWhitespace else { return nil }
        let slashed = afterBracket.drop(while: \.isWhitespace)
        guard slashed.first == "/", slashed.count >= 2, slashed.last == "/" else { return nil }
        let glosses = slashed.dropFirst().dropLast()
        return (String(trad), String(simp), String(pinyin), String(glosses))
    }

    private static let toneMarks: [Character: [Character]] = [
        "a": Array("āáǎàa"), "e": Array("ēéěèe"), "i": Array("īíǐìi"),
        "o": Array("ōóǒòo"), "u": Array("ūúǔùu"), "ü": Array("ǖǘǚǜü"),
    ]

    static func numberedToMarked(_ syllable: String) -> String {
        let s = syllable.replacingOccurrences(of: "u:", with: "ü").replacingOccurrences(of: "v", with: "ü")
        let chars = Array(s)
        guard chars.count >= 2, let toneDigit = chars.last?.wholeNumberValue, (1...5).contains(toneDigit),
              chars.dropLast().allSatisfy({ ("a"..."z").contains($0.lowercased()) || $0.lowercased() == "ü" })
        else { return s }
        let base = Array(chars.dropLast())
        if toneDigit == 5 { return String(base) }
        let lower = base.map { Character($0.lowercased()) }
        let lowerString = String(lower)
        let index: Int
        if let a = lower.firstIndex(of: "a") {
            index = a
        } else if let e = lower.firstIndex(of: "e") {
            index = e
        } else if lowerString.contains("ou"), let o = lower.firstIndex(of: "o") {
            index = o
        } else if let last = lower.lastIndex(where: { "aeiouü".contains($0) }) {
            index = last
        } else {
            return String(base)
        }
        guard let marks = toneMarks[lower[index]] else { return String(base) }
        var marked = marks[toneDigit - 1]
        if base[index].isUppercase { marked = Character(marked.uppercased()) }
        var result = base
        result[index] = marked
        return String(result)
    }

    static func pinyinMarks(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).map { numberedToMarked(String($0)) }.joined(separator: " ")
    }

    static func buildCEDICT(_ data: Data, to out: URL, progress: (Double) -> Void) throws -> Int {
        let writer = try DictionaryWriter(path: out.path, meta: ["id": "cedict", "source": "zh",
                                                                 "title": "CC-CEDICT", "license": "CC BY-SA 3.0"])
        let text = String(decoding: data, as: UTF8.self)
        // Splits on any line ending: the MDBG download uses Windows "\r\n", which Swift treats as a single
        // Character, so splitting on "\n" alone would see the whole file as one line.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let total = max(lines.count, 1)
        for (lineNumber, line) in lines.enumerated() {
            if lineNumber % 2000 == 0 { progress(Double(lineNumber) / Double(total) * 0.95) }
            if line.hasPrefix("#") { continue }
            guard let (trad, simp, pinyin, glosses) = parseCEDICTLine(String(line)) else { continue }
            var senses: [OutSense] = []
            for gloss in glosses.split(separator: "/", omittingEmptySubsequences: false) {
                let g = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
                if g.isEmpty || g.hasPrefix("CL:") { continue }
                senses.append(OutSense(pos: "", en: clean(g), zh: ""))
            }
            // Shorter, earlier headwords are usually more common; CC-CEDICT has no frequency data.
            let rank = simp.unicodeScalars.count * 100_000 + lineNumber
            try writer.add(headword: simp, reading: pinyinMarks(pinyin), senses: senses, rank: rank, forms: [simp, trad])
        }
        progress(0.97)
        return try writer.finish()
    }

    // MARK: - JMdict

    static func jmPOS(_ text: String) -> String {
        let p = text.lowercased()
        if p.hasPrefix("noun") || p.contains("noun (") { return "n." }
        if p.contains("verb") && !p.contains("adverb") { return "v." }
        if p.contains("adverb") { return "adv." }
        if p.contains("adjective") || p.contains("adjectival") || p.contains("pre-noun") { return "adj." }
        if p.contains("pronoun") { return "pron." }
        if p.contains("conjunction") { return "conj." }
        if p.contains("interjection") { return "int." }
        if p.contains("particle") { return "part." }
        if p.contains("counter") { return "ctr." }
        if p.contains("expression") { return "exp." }
        return ""
    }

    static func jmRank(_ priorities: [String]) -> Int {
        if priorities.isEmpty { return 900_000 }
        var best = 500_000
        for p in priorities {
            if p.hasPrefix("nf"), let n = Int(p.dropFirst(2)) {
                best = min(best, n * 500)
            } else if ["news1", "ichi1", "spec1", "gai1"].contains(p) {
                best = min(best, 2000)
            } else if ["news2", "ichi2", "spec2", "gai2"].contains(p) {
                best = min(best, 30000)
            }
        }
        return best
    }

    /// Apple's XMLParser doesn't expand JMdict's DTD entities (`<pos>&n;</pos>` arrives empty), so
    /// every `&name;` that the DTD declares is rewritten to its bare name first, and the name is
    /// mapped back to its description ("noun (common) (futsuumeishi)") while parsing.
    static func rewriteEntities(_ data: Data) -> (Data, [String: String]) {
        let bytes = [UInt8](data)
        // Entity declarations live in the DOCTYPE, before the root element.
        let rootMarker = Array("<JMdict>".utf8)
        var bodyStart = 0
        if let found = firstIndex(of: rootMarker, in: bytes) { bodyStart = found }
        let header = String(decoding: bytes[0..<bodyStart], as: UTF8.self)
        var entities: [String: String] = [:]
        if let regex = try? NSRegularExpression(pattern: "<!ENTITY\\s+(\\S+)\\s+\"([^\"]*)\"\\s*>") {
            let ns = header as NSString
            for match in regex.matches(in: header, range: NSRange(location: 0, length: ns.length)) {
                entities[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2))
            }
        }
        guard !entities.isEmpty else { return (data, [:]) }

        let names = Set(entities.keys.map { Array($0.utf8) })
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        out.append(contentsOf: bytes[0..<bodyStart])
        var i = bodyStart
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x26 {                                       // &
                var j = i + 1
                while j < bytes.count, j - i <= 64, bytes[j] != 0x3B, bytes[j] != 0x3C, bytes[j] != 0x26 { j += 1 }
                if j < bytes.count, bytes[j] == 0x3B {           // ;
                    let name = Array(bytes[(i + 1)..<j])
                    if names.contains(name) {
                        out.append(contentsOf: name)
                        i = j + 1
                        continue
                    }
                }
            }
            out.append(b)
            i += 1
        }
        return (Data(out), entities)
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let first = needle[0]
        var i = 0
        let limit = haystack.count - needle.count
        while i <= limit {
            if haystack[i] == first, Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    static func buildJMdict(_ data: Data, to out: URL, progress: @escaping (Double) -> Void) throws -> Int {
        let writer = try DictionaryWriter(path: out.path, meta: ["id": "jmdict", "source": "ja",
                                                                 "title": "JMdict", "license": "CC BY-SA 4.0 (EDRDG)"])
        progress(0.02)
        let (xml, entities) = rewriteEntities(data)
        let totalLines = max(xml.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }, 1)
        let parser = XMLParser(data: xml)
        let delegate = JMdictParserDelegate(entities: entities, writer: writer) { line in
            progress(0.05 + Double(line) / Double(totalLines) * 0.9)
        }
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        if !parser.parse(), delegate.writeError == nil, writer.count == 0 {
            throw parser.parserError ?? ImportError.unrecognized
        }
        if let error = delegate.writeError { throw error }
        progress(0.97)
        return try writer.finish()
    }
}

/// Streams JMdict `<entry>` elements into the writer (mirrors build_jmdict in the Python script).
private final class JMdictParserDelegate: NSObject, XMLParserDelegate {
    let entities: [String: String]
    let writer: DictionaryWriter
    let onLine: (Int) -> Void
    var writeError: Error?

    private var text = ""
    private var kebs: [String] = []
    private var rebs: [String] = []
    private var priorities: [String] = []
    private var senses: [DictionaryBuilder.OutSense] = []
    private var sensePOS: [String] = []
    private var senseGlosses: [String] = []
    private var lastPOS = ""
    private var inSense = false
    private var lastReportedLine = 0

    init(entities: [String: String], writer: DictionaryWriter, onLine: @escaping (Int) -> Void) {
        self.entities = entities
        self.writer = writer
        self.onLine = onLine
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch element {
        case "entry":
            kebs = []; rebs = []; priorities = []; senses = []; lastPOS = ""
        case "sense":
            inSense = true; sensePOS = []; senseGlosses = []
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        switch element {
        case "keb": if !value.isEmpty { kebs.append(value) }
        case "reb": if !value.isEmpty { rebs.append(value) }
        case "ke_pri", "re_pri": if !value.isEmpty { priorities.append(value) }
        case "pos": if inSense, !value.isEmpty { sensePOS.append(entities[value] ?? value) }
        case "gloss": if inSense, !value.isEmpty { senseGlosses.append(value) }
        case "sense":
            inSense = false
            let pos = sensePOS.first.map(DictionaryBuilder.jmPOS) ?? lastPOS
            lastPOS = pos
            if !senseGlosses.isEmpty {
                let english = DictionaryBuilder.clean(senseGlosses.prefix(3).joined(separator: ", "))
                senses.append(.init(pos: pos, en: english, zh: ""))
            }
        case "entry":
            let head = kebs.first ?? rebs.first ?? ""
            do {
                try writer.add(headword: head, reading: rebs.first ?? "", senses: senses,
                               rank: DictionaryBuilder.jmRank(priorities), forms: kebs + rebs)
            } catch {
                writeError = error
                parser.abortParsing()
            }
            if parser.lineNumber - lastReportedLine > 20_000 {
                lastReportedLine = parser.lineNumber
                onLine(parser.lineNumber)
            }
        default: break
        }
    }
}

// MARK: - SQLite writer

/// Writes the schema shared by every dictionary (see Tools/build_dictionaries.py).
final class DictionaryWriter {
    private var db: OpaquePointer?
    private var insertEntry: OpaquePointer?
    private var insertForm: OpaquePointer?
    private var insertSound: OpaquePointer?
    private let soundKeys: Bool
    private var nextID: Int64 = 1
    private(set) var count = 0
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `soundKeys` adds the `sounds` table (English): one row per single-word form with its `SoundKey`.
    init(path: String, meta: [String: String], soundKeys: Bool = false) throws {
        self.soundKeys = soundKeys
        try? FileManager.default.removeItem(atPath: path)
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw error("open") }
        try exec("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;")
        try exec("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE entries(id INTEGER PRIMARY KEY, headword TEXT, reading TEXT, senses TEXT, rank INTEGER);
            CREATE TABLE forms(form TEXT, entry_id INTEGER);
            """)
        if soundKeys { try exec("CREATE TABLE sounds(key TEXT, form TEXT, rank INTEGER);") }
        for (key, value) in meta.sorted(by: { $0.key < $1.key }) {
            try exec("INSERT INTO meta VALUES ('\(key)', '\(value.replacingOccurrences(of: "'", with: "''"))')")
        }
        try exec("BEGIN")
        guard sqlite3_prepare_v2(db, "INSERT INTO entries VALUES (?, ?, ?, ?, ?)", -1, &insertEntry, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT INTO forms VALUES (?, ?)", -1, &insertForm, nil) == SQLITE_OK
        else { throw error("prepare") }
        if soundKeys, sqlite3_prepare_v2(db, "INSERT INTO sounds VALUES (?, ?, ?)", -1, &insertSound, nil) != SQLITE_OK {
            throw error("prepare")
        }
    }

    deinit { close() }

    func add(headword: String, reading: String, senses: [DictionaryBuilder.OutSense], rank: Int, forms: [String]) throws {
        let kept = senses.filter { !$0.en.isEmpty || !$0.zh.isEmpty }
        guard !headword.isEmpty, !kept.isEmpty else { return }
        let id = nextID
        nextID += 1
        sqlite3_reset(insertEntry)
        sqlite3_bind_int64(insertEntry, 1, id)
        sqlite3_bind_text(insertEntry, 2, headword, -1, Self.transient)
        sqlite3_bind_text(insertEntry, 3, reading, -1, Self.transient)
        sqlite3_bind_text(insertEntry, 4, Self.json(kept), -1, Self.transient)
        sqlite3_bind_int64(insertEntry, 5, Int64(rank))
        guard sqlite3_step(insertEntry) == SQLITE_DONE else { throw error("insert entry") }
        // De-duplicated by exact bytes, like the Python script: Swift's String equality would merge
        // canonically equivalent spellings such as 兔 U+5154 and its compatibility form U+2F80F.
        let unique = Set(forms.filter { !$0.isEmpty }.map { Array($0.utf8) })
            .sorted { $0.lexicographicallyPrecedes($1) }
            .map { String(decoding: $0, as: UTF8.self) }
        for form in unique {
            sqlite3_reset(insertForm)
            sqlite3_bind_text(insertForm, 1, form, -1, Self.transient)
            sqlite3_bind_int64(insertForm, 2, id)
            guard sqlite3_step(insertForm) == SQLITE_DONE else { throw error("insert form") }
            if soundKeys, SoundKey.isSingleWord(form) {
                let key = SoundKey.make(form)
                guard !key.isEmpty else { continue }
                sqlite3_reset(insertSound)
                sqlite3_bind_text(insertSound, 1, key, -1, Self.transient)
                sqlite3_bind_text(insertSound, 2, form, -1, Self.transient)
                sqlite3_bind_int64(insertSound, 3, Int64(rank))
                guard sqlite3_step(insertSound) == SQLITE_DONE else { throw error("insert sound") }
            }
        }
        count += 1
    }

    /// Commits, indexes and compacts the file. Returns the number of entries written.
    func finish() throws -> Int {
        sqlite3_finalize(insertEntry); insertEntry = nil
        sqlite3_finalize(insertForm); insertForm = nil
        sqlite3_finalize(insertSound); insertSound = nil
        try exec("COMMIT")
        try exec("INSERT OR REPLACE INTO meta VALUES ('entries', '\(count)')")
        try exec("CREATE INDEX idx_forms_form ON forms(form); CREATE INDEX idx_entries_rank ON entries(rank);")
        if soundKeys { try exec("CREATE INDEX idx_sounds_key ON sounds(key, rank);") }
        try exec("VACUUM")
        close()
        return count
    }

    private func close() {
        if let insertEntry { sqlite3_finalize(insertEntry) }
        if let insertForm { sqlite3_finalize(insertForm) }
        if let insertSound { sqlite3_finalize(insertSound) }
        insertEntry = nil
        insertForm = nil
        insertSound = nil
        if let db { sqlite3_close(db) }
        db = nil
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(sql) }
    }

    private func error(_ step: String) -> NSError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        return NSError(domain: "DictionaryWriter", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: "Couldn't write the dictionary (\(message))."])
    }

    /// `[{"pos": "n.", "en": "...", "zh": "..."}]`, same shape the Python script writes.
    private static func json(_ senses: [DictionaryBuilder.OutSense]) -> String {
        var out = "["
        for (i, s) in senses.enumerated() {
            if i > 0 { out += ", " }
            out += "{\"pos\": \(quote(s.pos)), \"en\": \(quote(s.en)), \"zh\": \(quote(s.zh))}"
        }
        return out + "]"
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
