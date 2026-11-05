import Foundation

/// Installs and opens the offline dictionaries. Each one is downloaded from its official source
/// (or imported from Files), converted on the device, and then works offline.
@MainActor
final class DictionaryManager: ObservableObject {
    enum State: Equatable {
        case missing
        /// Fetching the official file; 0…1, or nil while the size is unknown.
        case downloading(progress: Double?)
        /// Converting a raw source file; 0…1.
        case building(progress: Double)
        case installed(entries: Int)
        case failed(String)
    }

    @Published private(set) var states: [DictionaryID: State] = [:]

    private var cache: [DictionaryID: LocalDictionary] = [:]

    init() {
        // Older versions asked for a download address; the links are built in now.
        UserDefaults.standard.removeObject(forKey: "dictionaries.downloadBaseURL")
        refresh()
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Data folders keep the app's former name, VocaQuest, so installed dictionaries survive the rename.
        let url = base.appendingPathComponent("VocaQuest/Dictionaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func installedURL(_ id: DictionaryID) -> URL? {
        let local = Self.folder.appendingPathComponent(id.fileName)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        // A dictionary can also be bundled by adding it to the app's resources.
        return Bundle.main.url(forResource: id.rawValue, withExtension: "sqlite")
    }

    func refresh() {
        for id in DictionaryID.allCases {
            if isBusy(id) { continue }
            if let dictionary = dictionary(id) {
                states[id] = .installed(entries: dictionary.entryCount)
            } else {
                states[id] = .missing
            }
        }
    }

    func state(_ id: DictionaryID) -> State { states[id] ?? .missing }

    func isBusy(_ id: DictionaryID) -> Bool {
        switch state(id) {
        case .downloading, .building: return true
        default: return false
        }
    }

    private func settle(_ id: DictionaryID) {
        if let dictionary = dictionary(id) {
            states[id] = .installed(entries: dictionary.entryCount)
        } else {
            states[id] = .missing
        }
    }

    func isInstalled(_ id: DictionaryID) -> Bool {
        if case .installed = state(id) { return true }
        return false
    }

    /// Opens (and caches) a dictionary, or returns nil if it isn't installed.
    func dictionary(_ id: DictionaryID) -> LocalDictionary? {
        if let cached = cache[id] { return cached }
        guard let url = installedURL(id), let dictionary = try? LocalDictionary(id: id, path: url.path) else { return nil }
        cache[id] = dictionary
        return dictionary
    }

    func dictionary(for language: AppLanguage) -> LocalDictionary? { dictionary(language.dictionary) }

    private static var workDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DictionaryImport", isDirectory: true)
    }

    /// Downloads the official file, converts it and installs it, all in one go.
    func download(_ id: DictionaryID) async {
        guard !isBusy(id) else { return }
        let workDir = Self.workDir
        let file = workDir.appendingPathComponent(UUID().uuidString + "-" + id.sourceURL.lastPathComponent)
        states[id] = .downloading(progress: nil)
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try await FileDownloader.download(id.sourceURL, to: file, expectedBytes: id.expectedBytes) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state(id) else { return }
                    self.states[id] = .downloading(progress: fraction)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            states[id] = .failed("The download didn't finish: \(error.localizedDescription) Check your connection and try again.")
            return
        }
        await convertAndInstall(file, requested: id)
    }

    /// Imports a file the person picked in Files: a raw ECDICT / CC-CEDICT / JMdict download
    /// (plain or .gz), converted here in the background, or an already built .sqlite.
    /// A raw file is installed as the dictionary it turns out to be, whichever row it was picked from.
    func importFile(_ url: URL, as requested: DictionaryID) {
        let workDir = Self.workDir
        let copy = workDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            states[requested] = .failed(error.localizedDescription)
            return
        }
        Task { await convertAndInstall(copy, requested: requested) }
    }

    /// Converts a local raw or .sqlite file in the background and installs the result. Deletes `file` when done.
    private func convertAndInstall(_ file: URL, requested: DictionaryID) async {
        let workDir = Self.workDir
        let token = UUID()
        importsInFlight.insert(token)
        states[requested] = .building(progress: 0)
        var target = requested
        do {
            let result = try await Task.detached(priority: .userInitiated) { () throws -> DictionaryBuilder.Result in
                try DictionaryBuilder.prepare(file, requested: requested, workDir: workDir) { id, fraction in
                    Task { @MainActor [weak self] in
                        self?.reportBuild(id, fraction, requested: requested, token: token)
                    }
                }
            }.value
            target = result.id
            importsInFlight.remove(token)
            try install(from: result.sqliteURL, as: result.id)
        } catch {
            importsInFlight.remove(token)
            states[target] = .failed(error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: file)
        if target != requested, isBusy(requested) { settle(requested) }
    }

    private var importsInFlight: Set<UUID> = []

    func reportImportFailure(_ error: Error, for id: DictionaryID) {
        states[id] = .failed(error.localizedDescription)
    }

    private func reportBuild(_ id: DictionaryID, _ fraction: Double, requested: DictionaryID, token: UUID) {
        // Progress ticks that arrive after the import finished are ignored.
        guard importsInFlight.contains(token) else { return }
        if id != requested, case .building = state(requested) { settle(requested) }
        states[id] = .building(progress: min(max(fraction, 0), 1))
    }

    private func install(from temp: URL, as id: DictionaryID) throws {
        // Validate before replacing anything.
        let probe = try LocalDictionary(id: id, path: temp.path)
        let count = probe.entryCount
        let destination = Self.folder.appendingPathComponent(id.fileName)
        cache[id] = nil
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        states[id] = .installed(entries: count)
    }

    func remove(_ id: DictionaryID) {
        cache[id] = nil
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(id.fileName))
        refresh()
    }
}

/// Downloads one file with progress reports (0…1). When the server doesn't send a length, progress is
/// estimated from `expectedBytes` and held below 99% until the download really ends.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var finishError: Error?
    private var lastReport = -1.0

    private init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    static func download(_ url: URL, to destination: URL, expectedBytes: Int64,
                         progress: @escaping @Sendable (Double?) -> Void) async throws {
        try await FileDownloader(destination: destination, expectedBytes: expectedBytes, progress: progress).run(url)
    }

    private func run(_ url: URL) async throws {
        // A serial queue: every delegate call below runs one at a time.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("DayDayUP/1.0 (personal vocabulary app)", forHTTPHeaderField: "User-Agent")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.addOperation {
                self.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction: Double
        if totalBytesExpectedToWrite > 0 {
            fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else if expectedBytes > 0 {
            fraction = min(Double(totalBytesWritten) / Double(expectedBytes), 0.99)
        } else {
            progress(nil)
            return
        }
        // About 100 updates for the whole download is plenty.
        if fraction - lastReport >= 0.01 || fraction >= 1 {
            lastReport = fraction
            progress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns, so it's moved right here.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finishError = NSError(domain: "Download", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "The server answered \(http.statusCode)."])
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finishError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? finishError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
