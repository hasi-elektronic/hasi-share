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
    /// How long `pendingUndo` stays offered (spec: 4 s; UI tests may stretch it).
    @ObservationIgnored public var undoWindow: Duration
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    /// Called after every synced change (the environment bumps `libraryVersion` and schedules a sync push).
    @ObservationIgnored public var onChange: @MainActor () -> Void
    /// Called after device-local changes (order, favorite categories): UI refresh only, no sync push.
    @ObservationIgnored public var onLocalChange: @MainActor () -> Void = {}
    private var keys: Set<String>
    /// The last toggle, offered for undo until `undoWindow` passes.
    public private(set) var pendingUndo: FavoriteTarget?
    /// Favorite state of `pendingUndo` before the toggle (undo restores it).
    @ObservationIgnored private var undoPriorState = false
    /// Saved manual order of that kind before the toggle (a removal prunes it; undo restores it).
    @ObservationIgnored private var undoPriorOrder: [String]?
    /// Source-scoped category ids (`"<sourceId>|<categoryId>"`), per device.
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

    /// Flips the favorite state immediately and offers undo. Returns the resulting state (unchanged
    /// when the database write failed).
    @discardableResult
    public func toggle(_ t: FavoriteTarget) -> Bool {
        let prior = keys.contains(t.contentKey)
        let priorOrder = kv.value([String].self, forKey: orderKey(t.kind))
        guard apply(!prior, t) else { return prior }
        pendingUndo = t
        undoPriorState = prior
        undoPriorOrder = priorOrder
        undoTask?.cancel()
        let window = undoWindow
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.pendingUndo = nil
        }
        return !prior
    }

    /// Restores the state before the last toggle.
    public func undo() {
        guard let t = pendingUndo else { return }
        undoTask?.cancel()
        pendingUndo = nil
        if keys.contains(t.contentKey) != undoPriorState { apply(undoPriorState, t) }
        // Back into its manual slot (keys removed meanwhile drop out in `orderedKeys`).
        if let order = undoPriorOrder { kv.setValue(order, forKey: orderKey(t.kind)) }
        undoPriorOrder = nil
    }

    /// Optimistic write: cache first, database second – never blocking the UI: while a refresh commit holds the
    /// database the change waits in the library's queue and overlays its reads (read-your-writes).
    @discardableResult
    private func apply(_ on: Bool, _ t: FavoriteTarget) -> Bool {
        let was = keys.contains(t.contentKey)
        if on { keys.insert(t.contentKey) } else { keys.remove(t.contentKey) }
        do {
            try library.setFavoriteWithoutBlocking(on, contentKey: t.contentKey, title: t.title, kind: t.kind,
                                                   posterUrl: t.posterUrl, nowMs: now())
        } catch {   // written at once and failed: the cache shows the real state again
            if was { keys.insert(t.contentKey) } else { keys.remove(t.contentKey) }
            return false
        }
        if !on { pruneOrder(kind: t.kind, key: t.contentKey) }
        onChange()
        return true
    }

    // MARK: Order (device-local)

    private func orderKey(_ kind: ContentKind) -> String { "fav.order.\(kind.rawValue)" }

    /// A removed favorite leaves the saved order; re-adding it counts as new (newest-first part).
    private func pruneOrder(kind: ContentKind, key: String) {
        guard var saved = kv.value([String].self, forKey: orderKey(kind)), saved.contains(key) else { return }
        saved.removeAll { $0 == key }
        kv.setValue(saved, forKey: orderKey(kind))
    }

    /// Manually ordered keys first, then every other favorite newest-first.
    public func orderedKeys(kind: ContentKind) -> [String] {
        let newestFirst = ((try? library.favorites(kind: kind)) ?? []).map(\.contentKey)
        let present = Set(newestFirst)
        let saved = (kv.value([String].self, forKey: orderKey(kind)) ?? []).filter { present.contains($0) }
        let savedSet = Set(saved)
        return saved + newestFirst.filter { !savedSet.contains($0) }
    }

    /// Moves favorites (SwiftUI `onMove` offsets). With `within`, the offsets refer to that subset
    /// of `orderedKeys(kind:)` (e.g. the current source's favorites); other keys keep their slots.
    public func move(kind: ContentKind, from: IndexSet, to: Int, within subset: [String]? = nil) {
        let full = orderedKeys(kind: kind)
        let present = Set(full)
        // Offsets refer to `subset` exactly as passed: move first, then drop keys that are no favorite.
        var moved = subset ?? full
        moved.move(from: from, to: to)
        moved = moved.filter { present.contains($0) }
        let visible = moved
        var result = full
        if subset != nil {
            let visibleSet = Set(visible)
            var next = moved.makeIterator()
            for index in result.indices where visibleSet.contains(result[index]) {
                if let key = next.next() { result[index] = key }
            }
        } else {
            result = moved
        }
        kv.setValue(result, forKey: orderKey(kind))
        onLocalChange()
    }

    // MARK: Favorite categories (device-local, source-scoped)

    public static func categoryKey(sourceId: String, categoryId: String) -> String { "\(sourceId)|\(categoryId)" }

    public func isFavoriteCategory(sourceId: String, categoryId: String) -> Bool {
        favoriteCategoryIds.contains(Self.categoryKey(sourceId: sourceId, categoryId: categoryId))
    }

    /// Favorite category ids of one source (unscoped provider ids).
    public func favoriteCategoryIds(sourceId: String) -> Set<String> {
        let prefix = sourceId + "|"
        return Set(favoriteCategoryIds.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    public func toggleCategory(sourceId: String, categoryId: String) {
        let id = Self.categoryKey(sourceId: sourceId, categoryId: categoryId)
        if favoriteCategoryIds.contains(id) { favoriteCategoryIds.remove(id) } else { favoriteCategoryIds.insert(id) }
        kv.setValue(favoriteCategoryIds, forKey: Self.categoriesKey)
        onLocalChange()
    }
}
