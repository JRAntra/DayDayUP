import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            ScrollView { DailyReviewSettingsView().padding(20) }
                .tabItem { Label("Daily review", systemImage: "calendar.badge.clock") }
            ScrollView { DictionariesSettingsView().padding(20) }
                .tabItem { Label("Dictionaries", systemImage: "books.vertical") }
            ScrollView { PronunciationSettingsView().padding(20) }
                .tabItem { Label("Pronunciation", systemImage: "speaker.wave.2") }
            ScrollView { DataSettingsView().padding(20) }
                .tabItem { Label("Your data", systemImage: "externaldrive") }
        }
        #else
        List {
            NavigationLink(destination: ScrollView { DailyReviewSettingsView().padding(16) }.navigationTitle("Daily review")) {
                Label("Daily review", systemImage: "calendar.badge.clock")
            }
            NavigationLink(destination: ScrollView { DictionariesSettingsView().padding(16) }.navigationTitle("Dictionaries")) {
                Label("Dictionaries", systemImage: "books.vertical.fill")
            }
            NavigationLink(destination: ScrollView { PronunciationSettingsView().padding(16) }.navigationTitle("Pronunciation")) {
                Label("Pronunciation", systemImage: "speaker.wave.2.fill")
            }
            NavigationLink(destination: ScrollView { DataSettingsView().padding(16) }.navigationTitle("Your data")) {
                Label("Your data", systemImage: "externaldrive.fill")
            }
        }
        .navigationTitle("Settings")
        #endif
    }
}

/// Settings most people never need, folded away under a heading.
private struct AdvancedSection<Content: View>: View {
    var title = "Advanced"
    @ViewBuilder var content: () -> Content
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(title).font(Typeface.title(18)).foregroundColor(Palette.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundColor(Palette.ink.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            if expanded { content() }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Typeface.title(18))
            content()
            if let footer {
                Text(footer).font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Daily review

struct DailyReviewSettingsView: View {
    @EnvironmentObject private var planner: TodayPlanner
    @EnvironmentObject private var reminders: ReminderService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "New words",
                            footer: "How many new words Today introduces per language pair each day. New words wait while 20 or more reviews are due, so a backlog clears first.") {
                Stepper(value: $planner.newPerDay, in: TodayPlanner.newPerDayRange) {
                    Text("\(planner.newPerDay) new words a day").font(Typeface.body(15))
                }
            }
            SettingsSection(title: "Reminder",
                            footer: reminderFooter) {
                Toggle("Remind me when reviews are due", isOn: $reminders.enabled).font(Typeface.body(15))
                if reminders.enabled {
                    DatePicker("Time", selection: Binding(get: { reminders.time }, set: { reminders.time = $0 }),
                               displayedComponents: .hourAndMinute)
                        .font(Typeface.body(15))
                }
            }
            SettingsSection(title: "How reviews are scheduled",
                            footer: "Based on the Ebbinghaus forgetting curve. A miss at any time sends a word back to the start, due tomorrow, and into the Review Book until it passes two reviews in a row.") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A new word starts the first time you answer it. Each correct review on or after its due day moves it up a step:")
                        .font(Typeface.body(14))
                    Text(ReviewSchedule.gaps.map { "\($0) day\($0 == 1 ? "" : "s")" }.joined(separator: " → ") + " → remembered")
                        .font(Typeface.label(14)).foregroundColor(Palette.grape)
                    Text("Remembered words come back every \(ReviewSchedule.maintenanceGap) days. Answering before a word is due never moves it up.")
                        .font(Typeface.body(14))
                }
            }
        }
        .task { await reminders.updateAuthorization() }
    }

    private var reminderFooter: String {
        switch reminders.authorization {
        case .denied:
            return "Notifications are turned off for DayDayUP in system Settings, so reminders can't be shown. The app icon still shows how many reviews are due."
        case .notDetermined:
            return "DayDayUP asks for permission the first time you open Today."
        default:
            return "One notification a day at this time, only on days with reviews due. The app icon shows how many are due."
        }
    }
}

// MARK: - Dictionaries

struct DictionariesSettingsView: View {
    @EnvironmentObject private var dictionaries: DictionaryManager
    // Kept separate from the picker's isPresented flag: on iOS the picker turns isPresented off
    // *before* it calls the completion handler, so a target stored in that flag would already be gone.
    @State private var showImporter = false
    @State private var importTarget: DictionaryID = .ecdict

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "Offline dictionaries",
                            footer: "Download fetches the dictionary from its official source (ECDICT on GitHub, CC-CEDICT from MDBG, JMdict from EDRDG), converts it on this device and installs it. Already have the file? Import accepts the same downloads, plain or .gz, and .sqlite files built with Tools/build_dictionaries.py.") {
                ForEach(DictionaryID.allCases) { id in
                    row(id)
                    if id != DictionaryID.allCases.last { Divider() }
                }
            }
            AdvancedSection { SourcesSettingsView() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): dictionaries.importFile(url, as: importTarget)
            case .failure(let error): dictionaries.reportImportFailure(error, for: importTarget)
            }
        }
    }

    private func startImport(_ id: DictionaryID) {
        importTarget = id
        showImporter = true
    }

    private func row(_ id: DictionaryID) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(id.title).font(Typeface.title(16))
                Text(id.sourceName).font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.55))
                status(id)
            }
            Spacer()
            switch dictionaries.state(id) {
            case .downloading(let progress?):
                ProgressView(value: progress).frame(width: 90)
            case .downloading(nil):
                ProgressView().controlSize(.small)
            case .building(let progress):
                ProgressView(value: progress).frame(width: 90)
            case .installed:
                Button("Replace") { startImport(id) }.buttonStyle(.borderless)
                Button("Remove", role: .destructive) { dictionaries.remove(id) }.buttonStyle(.borderless)
            default:
                Button("Download") { Task { await dictionaries.download(id) } }
                    .buttonStyle(ChunkyButtonStyle(height: 34, fullWidth: false))
                    .lineLimit(1).fixedSize()
                Button("Import") { startImport(id) }
                    .buttonStyle(OutlineChunkyButtonStyle())
                    .lineLimit(1).fixedSize()
            }
        }
    }

    @ViewBuilder private func status(_ id: DictionaryID) -> some View {
        switch dictionaries.state(id) {
        case .installed(let entries):
            Label("Installed · \(entries.formatted()) entries", systemImage: "checkmark.circle.fill")
                .font(Typeface.label(12)).foregroundColor(Palette.mint)
        case .downloading(let progress):
            Text(progress.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…")
                .font(Typeface.label(12)).foregroundColor(Palette.ink.opacity(0.6))
        case .building(let progress):
            Text("Converting… \(Int(progress * 100))%").font(Typeface.label(12)).foregroundColor(Palette.ink.opacity(0.6))
        case .failed(let message):
            Text(message).font(Typeface.label(12)).foregroundColor(Palette.cherry)
                .fixedSize(horizontal: false, vertical: true)
        case .missing:
            Text("Not installed · \(id.downloadSize) download").font(Typeface.label(12)).foregroundColor(Palette.ink.opacity(0.5))
        }
    }
}

// MARK: - Sources

struct SourcesSettingsView: View {
    @EnvironmentObject private var settings: LookupSourceSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "Lookup order",
                            footer: "DayDayUP tries the sources from top to bottom and uses the first one that finds the word. If none do, it suggests similar words from the offline dictionary.") {
                ForEach(Array(settings.sources.enumerated()), id: \.element.id) { index, source in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(get: { settings.sources[index].enabled },
                                             set: { settings.sources[index].enabled = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.kind.title).font(Typeface.title(15))
                                Text(source.kind.detail).font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.6))
                            }
                        }
                        VStack(spacing: 2) {
                            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == settings.sources.count - 1)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityElement(children: .contain)
                    }
                }
                Button("Reset to default order") { settings.resetToDefaults() }.buttonStyle(.borderless)
            }
            SettingsSection(title: "MyMemory email",
                            footer: "Optional. Adding an email raises MyMemory's free daily limit from about 5,000 to about 50,000 characters.") {
                TextField("you@example.com", text: $settings.myMemoryEmail)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
            }
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard settings.sources.indices.contains(target) else { return }
        settings.sources.swapAt(index, target)
    }
}

// MARK: - Pronunciation

struct PronunciationSettingsView: View {
    @EnvironmentObject private var speech: SpeechService
    @State private var cacheSize = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "Human pronunciation",
                            footer: "English words play a real native-speaker recording (Wiktionary) when one exists. Everything else uses an Azure neural voice. Audio is saved after the first play, so it then works offline too.") {
                Toggle("Use real recordings for English when available", isOn: $speech.useRecordings)
                Picker("English accent", selection: $speech.englishAccent) {
                    ForEach(SpeechService.EnglishAccent.allCases) { Text($0.label).tag($0) }
                }
                if let source = speech.lastSource {
                    Text("Last word played: \(source.label)").font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.6))
                }
            }
            SettingsSection(title: "Speed") {
                HStack {
                    Image(systemName: "tortoise.fill")
                    Slider(value: $speech.rate, in: 0.25...0.6)
                    Image(systemName: "hare.fill")
                }
                .foregroundColor(Palette.grape)
            }
            AdvancedSection {
                SettingsSection(title: "Azure neural voice",
                                footer: "Create a free Speech resource at portal.azure.com (Free F0 tier: 500,000 characters a month), then paste one of its keys and its region here. The key is kept in your Keychain. Without a key, Apple's voice is used.") {
                    SecureField("Azure Speech key", text: $speech.azureKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("Region, for example eastus", text: $speech.azureRegion)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    ForEach(AppLanguage.allCases) { language in
                        HStack {
                            Picker(language.displayName, selection: Binding(
                                get: { speech.neuralVoice(for: language).id },
                                set: { speech.setNeuralVoice($0, for: language) })) {
                                ForEach(SpeechService.neuralVoices(for: language, accent: speech.englishAccent)) { voice in
                                    Text(voice.label).tag(voice.id)
                                }
                            }
                            Button { speech.speak(sample(language), reading: sampleReading(language), language: language) } label: {
                                Image(systemName: "play.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Play a sample")
                        }
                    }
                    if let problem = speech.lastProblem {
                        Text(problem).font(Typeface.label(12)).foregroundColor(Palette.cherry)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                SettingsSection(title: "Offline voice",
                                footer: "Used when you're offline or no Azure key is set. For a better offline voice, download an Enhanced or Premium voice in your device's Accessibility → Spoken Content settings.") {
                    ForEach(AppLanguage.allCases) { language in
                        Picker(language.displayName, selection: Binding(
                            get: { speech.selectedVoiceID(for: language) ?? "" },
                            set: { speech.setVoice($0.isEmpty ? nil : $0, for: language) })) {
                            Text("Automatic").tag("")
                            ForEach(speech.voices(for: language), id: \.identifier) { voice in
                                Text("\(voice.name) · \(voice.language) · \(SpeechService.qualityLabel(voice))").tag(voice.identifier)
                            }
                        }
                    }
                }
                SettingsSection(title: "Saved audio") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file))
                            .font(Typeface.body(14))
                        Spacer()
                        Button("Clear") { speech.clearAudioCache(); cacheSize = speech.audioCacheSize }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .onAppear { cacheSize = speech.audioCacheSize }
    }

    private func sample(_ language: AppLanguage) -> String {
        switch language {
        case .english: return "vocabulary"
        case .chinese: return "词汇"
        case .japanese: return "語彙"
        }
    }

    private func sampleReading(_ language: AppLanguage) -> String? {
        switch language {
        case .english: return nil
        case .chinese: return "cí huì"
        case .japanese: return "ごい"
        }
    }
}

// MARK: - Data

struct DataSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var gamification: GamificationService
    @EnvironmentObject private var settings: LookupSourceSettings
    @EnvironmentObject private var dictionaries: DictionaryManager

    @State private var backupDocument = BackupDocument(data: Data())
    @State private var exporting = false
    @State private var importing = false
    @State private var pendingRestore: BackupFile?
    @State private var message: String?

    private var backupName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "DayDayUP backup \(f.string(from: Date()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "Full backup",
                            footer: "One file with every table, meaning, progress ring, the Review Book, your streak, achievements and settings. Save it to iCloud Drive to move between your iPhone and Mac.") {
                #if os(iOS)
                // Stacked on iPhone, where the two labels don't fit side by side.
                VStack(spacing: 10) {
                    Button { exportBackup() } label: { Label("Export backup", systemImage: "square.and.arrow.up") }
                        .buttonStyle(ChunkyButtonStyle())
                    Button { importing = true } label: { Label("Restore backup", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                        .buttonStyle(OutlineChunkyButtonStyle())
                }
                #else
                HStack {
                    Button { exportBackup() } label: { Label("Export backup", systemImage: "square.and.arrow.up") }
                        .buttonStyle(ChunkyButtonStyle(fullWidth: false))
                    Button { importing = true } label: { Label("Restore backup", systemImage: "square.and.arrow.down") }
                        .buttonStyle(OutlineChunkyButtonStyle())
                }
                #endif
            }
            #if os(iOS)
            NavigationLink(destination: RecentlyDeletedView()) {
                HStack {
                    Label("Recently Deleted", systemImage: "trash").font(Typeface.title(17)).foregroundColor(Palette.ink)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(Palette.ink.opacity(0.35))
                }
                .card()
            }
            .buttonStyle(.plain)
            #endif
            AboutSettingsView()
        }
        .fileExporter(isPresented: $exporting, document: backupDocument, contentType: .json, defaultFilename: backupName) { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    pendingRestore = try BackupService.decode(try Data(contentsOf: url))
                } catch {
                    message = error.localizedDescription
                }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .alert("Replace everything with this backup?",
               isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button("Cancel", role: .cancel) { pendingRestore = nil }
            Button("Replace", role: .destructive) { restore() }
        } message: {
            if let file = pendingRestore {
                Text("The backup from \(file.exportedAt.formatted(date: .abbreviated, time: .shortened)) has \(file.words.count) words. Your current data is saved to a safety backup first.")
            }
        }
        .alert("DayDayUP", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func exportBackup() {
        do {
            backupDocument = BackupDocument(data: try BackupService.makeBackup(context: repository.context))
            exporting = true
        } catch {
            message = error.localizedDescription
        }
    }

    private func restore() {
        guard let file = pendingRestore else { return }
        pendingRestore = nil
        do {
            let safety = try BackupService.writeSafetyBackup(context: repository.context)
            BackupService.restore(file, repository: repository)
            gamification.refresh()
            settings.reload()
            message = "Restored \(file.words.count) words. Your previous data was saved as “\(safety.lastPathComponent)”."
        } catch {
            message = "The restore was cancelled because the safety backup couldn't be written: \(error.localizedDescription)"
        }
    }
}

// MARK: - Recently deleted

struct RecentlyDeletedView: View {
    @EnvironmentObject private var repository: VocabRepository
    @State private var batches: [DeletedBatch] = []
    @State private var confirmEmpty = false

    var body: some View {
        Group {
            if batches.isEmpty {
                EmptyStateView(symbol: "trash", title: "Nothing deleted",
                               message: "Deleted words, folders, categories and language pairs stay here for 30 days.")
            } else {
                List {
                    ForEach(batches) { batch in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(batch.title).font(Typeface.title(16))
                                if !batch.detail.isEmpty {
                                    Text(batch.detail).font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.65)).lineLimit(2)
                                }
                                Text("Deleted \(batch.deletedAt.formatted(date: .abbreviated, time: .shortened)) · removed on \(batch.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.5))
                            }
                            Spacer()
                            Button("Restore") { repository.restore(batch); reload() }
                                .buttonStyle(ChunkyButtonStyle(color: Palette.mint, height: 34, fullWidth: false))
                            Button(role: .destructive) { repository.purge(batch); reload() } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete now")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Recently Deleted")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Empty") { confirmEmpty = true }.disabled(batches.isEmpty)
            }
        }
        .confirmationDialog("Permanently delete everything in Recently Deleted?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { repository.emptyRecentlyDeleted(); reload() }
        }
        .onAppear(perform: reload)
        // Stay current while open: deletions made elsewhere (another window, the table) show up at once.
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave, object: repository.context)) { _ in
            reload()
        }
    }

    private func reload() { batches = repository.deletedBatches() }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "DayDayUP") {
                Text("A personal vocabulary app for English, Chinese and Japanese. Your library is stored on this device.")
                    .font(Typeface.body(14))
            }
            SettingsSection(title: "Dictionary data") {
                ForEach(DictionaryID.allCases) { id in
                    Text(id.license).font(Typeface.body(13))
                }
                Text("Online lookups use MyMemory (translated.net) and Wiktionary (CC BY-SA). Pronunciation uses native-speaker recordings from Wiktionary and Wikimedia Commons (CC BY-SA), Azure neural voices with your own key, and Apple's built-in voices offline.")
                    .font(Typeface.body(13))
            }
        }
    }
}
