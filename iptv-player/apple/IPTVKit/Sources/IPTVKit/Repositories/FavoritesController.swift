import Foundation
import IPTVCore
import Observation

public struct FavoriteTarget: Sendable, Hashable {
    public var contentKey: String
    public var title: String
    public var kind: ContentKind
    public var posterUrl: String?
    public init(contentKey: String, title: String, kind: ContentKind, posterUrl: String?) {
        self.contentKey = contentKey; self.title = title; self.kind = kind; self.posterUrl = posterUrl
    }
}

/// One-tap favorites (spec §2): in-memory set for O(1) lookups, optimistic toggle, 4 s undo,
/// device-local manual order and favorite categories. The order is NOT synced (CONTRACT unchanged).
@MainActor
@Observable
public final class FavoritesController {
    @ObservationIgnored private let library: LibraryRepository
    @ObservationIgnored private let kv: any KeyValueStore
    /// Clock (epoch ms); the environment swaps in the license clock.
    @ObservationIgnored public var now: @MainActor () -> Int64
    @ObservationIgnored private let undoWindow: Duration
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    /// Called after every local change (the environment bumps `libraryVersion` and schedules a sync push).
    @ObservationIgnored public var onChange: @MainActor () -> Void
    private var keys: Set<String>
    public private(set) var pendingUndo: FavoriteTarget?
    public private(set) var favoriteCategoryIds: Set<String>

    public init(library: LibraryRepository, kv: any KeyValueStore, now: @escaping @MainActor () -> Int64,
                onChange: @escaping @MainActor () -> Void = {}, undoWindow: Duration = .seconds(4)) {
        self.library = library; self.kv = kv; self.now = now; self.onChange = onChange; self.undoWindow = undoWindow
        self.keys = Set(((try? library.favorites()) ?? []).map(\.contentKey))
        self.favoriteCategoryIds = kv.value(Set<String>.self, forKey: Self.categoriesKey) ?? []
    }

    private static let categoriesKey = "fav.categories"

    /// Re-reads the favorites set from the database (after a sync merged remote changes).
    public func reload() {
        keys = Set(((try? library.favorites()) ?? []).map(\.contentKey))
    }

    public func isFavorite(_ contentKey: String) -> Bool { keys.contains(contentKey) }

    @discardableResult
    public func toggle(_ t: FavoriteTarget) -> Bool {
        let on = !keys.contains(t.contentKey)
        apply(on, t)
        pendingUndo = t
        undoTask?.cancel()
        let window = undoWindow
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.pendingUndo = nil
        }
        return on
    }

    public func undo() {
        guard let t = pendingUndo else { return }
        undoTask?.cancel()
        apply(!keys.contains(t.contentKey), t)
        pendingUndo = nil
    }

    private func apply(_ on: Bool, _ t: FavoriteTarget) {
        if on { keys.insert(t.contentKey) } else { keys.remove(t.contentKey) }
        _ = try? library.setFavorite(on, contentKey: t.contentKey, title: t.title, kind: t.kind,
                                     posterUrl: t.posterUrl, nowMs: now())
        onChange()
    }

    private func orderKey(_ kind: ContentKind) -> String { "fav.order.\(kind.rawValue)" }

    /// Manually ordered keys first, then every other favorite newest-first.
    public func orderedKeys(kind: ContentKind) -> [String] {
        let newestFirst = ((try? library.favorites(kind: kind)) ?? []).map(\.contentKey)
        let present = Set(newestFirst)
        let saved = (kv.value([String].self, forKey: orderKey(kind)) ?? []).filter { present.contains($0) }
        let savedSet = Set(saved)
        return saved + newestFirst.filter { !savedSet.contains($0) }
    }

    public func move(kind: ContentKind, from: IndexSet, to: Int) {
        var list = orderedKeys(kind: kind)
        // SwiftUI `move(fromOffsets:toOffset:)` semantics without importing SwiftUI.
        let moving = from.filter { list.indices.contains($0) }.map { list[$0] }
        let removedBefore = from.filter { $0 < to }.count
        for index in from.sorted(by: >) where list.indices.contains(index) { list.remove(at: index) }
        let target = min(max(to - removedBefore, 0), list.count)
        list.insert(contentsOf: moving, at: target)
        kv.setValue(list, forKey: orderKey(kind))
        onChange()
    }

    public func toggleCategory(_ id: String) {
        if favoriteCategoryIds.contains(id) { favoriteCategoryIds.remove(id) } else { favoriteCategoryIds.insert(id) }
        kv.setValue(favoriteCategoryIds, forKey: Self.categoriesKey)
        onChange()
    }
}
