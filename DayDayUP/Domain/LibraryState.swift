import CoreData
import Foundation

/// Per-device Library state: the recently opened lists and which empty language pairs were opened on purpose.
/// Neither is part of backups (see SIMPLIFICATION_PLAN.md).
@MainActor
final class LibraryState: ObservableObject {
    static let recentLimit = 5
    private static let recentKey = "library.recentLists"
    private static let revealedKey = "library.revealedPairs"
    private static let hiddenBannersKey = "library.hiddenDictionaryBanners"

    /// Keys like "category:<uuid>", newest first.
    @Published private(set) var recentKeys: [String]
    /// Empty pairs the person chose to open from "Add a language pair". Pairs with words always show.
    @Published private(set) var revealedPairIDs: Set<String>
    /// Pairs whose missing-dictionary banner was dismissed with "Not now".
    @Published private(set) var hiddenBannerPairIDs: Set<String>

    private let repository: VocabRepository

    init(repository: VocabRepository) {
        self.repository = repository
        let defaults = UserDefaults.standard
        recentKeys = defaults.stringArray(forKey: Self.recentKey) ?? []
        revealedPairIDs = Set(defaults.stringArray(forKey: Self.revealedKey) ?? [])
        hiddenBannerPairIDs = Set(defaults.stringArray(forKey: Self.hiddenBannersKey) ?? [])
    }

    // MARK: Recent lists

    static func key(for target: WordListTarget) -> String? {
        switch target {
        case .review: return "review"
        case .pair(let p): return p.id.map { "pair:\($0.uuidString)" }
        case .category(let c): return c.id.map { "category:\($0.uuidString)" }
        case .unfiled(let c): return c.id.map { "unfiled:\($0.uuidString)" }
        case .folder(let f): return f.id.map { "folder:\($0.uuidString)" }
        }
    }

    func recordOpened(_ target: WordListTarget) {
        guard let key = Self.key(for: target) else { return }
        var keys = recentKeys.filter { $0 != key }
        keys.insert(key, at: 0)
        // Keep a few extra, so deleted lists dropping out don't leave the section short.
        recentKeys = Array(keys.prefix(Self.recentLimit * 2))
        UserDefaults.standard.set(recentKeys, forKey: Self.recentKey)
    }

    /// Turns a stored key back into a list, or nil if it no longer exists.
    func target(for key: String) -> WordListTarget? {
        if key == "review" { return .review }
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        // Deleted lists (still in Recently Deleted) drop out.
        switch parts[0] {
        case "pair": return repository.pair(id: id).flatMap { $0.deletedAt == nil ? .pair($0) : nil }
        case "category": return repository.category(id: id).flatMap { $0.deletedAt == nil ? .category($0) : nil }
        case "unfiled": return repository.category(id: id).flatMap { $0.deletedAt == nil ? .unfiled($0) : nil }
        case "folder": return repository.folder(id: id).flatMap { $0.deletedAt == nil ? .folder($0) : nil }
        default: return nil
        }
    }

    /// The last few lists that still exist, newest first.
    var recentTargets: [(key: String, target: WordListTarget)] {
        Array(recentKeys.compactMap { key in target(for: key).map { (key, $0) } }.prefix(Self.recentLimit))
    }

    // MARK: Empty pairs

    func isVisible(_ pair: LanguagePairMO) -> Bool {
        pair.hasWords || pair.id.map { revealedPairIDs.contains($0.uuidString) } ?? false
    }

    func reveal(_ pair: LanguagePairMO) {
        guard let id = pair.id?.uuidString else { return }
        revealedPairIDs.insert(id)
        UserDefaults.standard.set(Array(revealedPairIDs), forKey: Self.revealedKey)
    }

    // MARK: Dictionary banner

    func isBannerHidden(for pair: LanguagePairMO) -> Bool {
        pair.id.map { hiddenBannerPairIDs.contains($0.uuidString) } ?? false
    }

    func hideBanner(for pair: LanguagePairMO) {
        guard let id = pair.id?.uuidString else { return }
        hiddenBannerPairIDs.insert(id)
        UserDefaults.standard.set(Array(hiddenBannerPairIDs), forKey: Self.hiddenBannersKey)
    }
}
