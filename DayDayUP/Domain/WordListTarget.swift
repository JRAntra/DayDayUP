import SwiftUI

/// What a word list is showing.
enum WordListTarget: Hashable {
    case review
    case pair(LanguagePairMO)
    case category(CategoryMO)
    case unfiled(CategoryMO)
    case folder(FolderMO)

    var scope: WordScope {
        switch self {
        case .review: return .reviewBook
        case .pair(let p): return WordScope(pairID: p.id)
        case .category(let c): return WordScope(pairID: c.pair?.id, categoryID: c.id)
        case .unfiled(let c): return WordScope(pairID: c.pair?.id, categoryID: c.id, unfiledOnly: true)
        case .folder(let f): return WordScope(pairID: f.category?.pair?.id, categoryID: f.category?.id, folderID: f.id)
        }
    }

    var title: String {
        switch self {
        case .review: return "Review Book"
        case .pair(let p): return p.title
        case .category(let c): return c.displayName
        case .unfiled(let c): return "\(c.displayName) · Unfiled"
        case .folder(let f): return f.displayName
        }
    }

    var pair: LanguagePairMO? {
        switch self {
        case .review: return nil
        case .pair(let p): return p
        case .category(let c), .unfiled(let c): return c.pair
        case .folder(let f): return f.category?.pair
        }
    }

    /// New words can be added only where a category is known.
    var category: CategoryMO? {
        switch self {
        case .category(let c), .unfiled(let c): return c
        case .folder(let f): return f.category
        default: return nil
        }
    }

    var folder: FolderMO? {
        if case .folder(let f) = self { return f }
        return nil
    }

    var accent: Color { pair?.accent ?? Palette.cherry }

    var symbol: String {
        switch self {
        case .review: return "arrow.uturn.backward.circle.fill"
        case .pair: return "square.stack.3d.up.fill"
        case .category(let c): return c.symbol
        case .unfiled: return "tray"
        case .folder: return "folder.fill"
        }
    }

    /// Where the list lives, shown under its name in Recent.
    var recentContext: String? {
        switch self {
        case .review: return nil
        case .pair: return "All words"
        case .category(let c): return c.pair?.title
        case .unfiled(let c): return c.pair?.title
        case .folder(let f): return [f.category?.displayName, f.category?.pair?.title].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// One-line name for the Mac sidebar's Recent group.
    var recentTitle: String {
        switch self {
        case .pair(let p): return "All words · \(p.title)"
        case .folder(let f): return "\(f.displayName) · \(f.category?.displayName ?? "")"
        default: return title
        }
    }
}
