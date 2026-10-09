import Foundation
import IPTVCore

/// Sizes and keys of the iCloud key-value store (docs/ARCHITECTURE.md §6.1). Apple's limits: 1 MB per user and
/// app, 1024 keys, keys ≤ 64 bytes. We use three keys and stay below ~900 KB.
public enum CloudSyncLimits {
    public static let quotaBytes = 1_048_576
    /// Compressed library (favorites + 300 progress items + tombstones). Lowered after a quota violation.
    public static let libraryBudgetBytes = 640_000
    /// After repeated quota violations the library never goes below this.
    public static let minLibraryBudgetBytes = 16_000
    public static let sourcesBudgetBytes = 64_000
    public static let prefsBudgetBytes = 192_000
    public static let maxFavorites = DurableStateMirror.maxFavorites
    public static let maxProgress = DurableStateMirror.maxProgress
    /// Library tombstones kept (newest first, ~40 bytes each compressed).
    public static let maxTombstones = 2_000
    /// Deleted sources / favorites / cleared preferences stay as tombstones this long: a device that was offline
    /// longer could bring a deleted item back (documented limit). Absence from the remote never deletes anything –
    /// a fresh device may overwrite the iCloud value before its first download; the others then write again.
    public static let tombstoneTTLms: Int64 = 365 * 86_400_000

    static let sourcesKey = "nova.sources.v1"
    static let prefsKey = "nova.prefs.v1"
    static let libraryKey = "nova.library.v1"
}

/// One register of a last-writer-wins map (`nil` value = deleted).
struct CloudEntry<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var at: Int64
    var val: Value?
}

/// A versioned last-writer-wins map as stored in one iCloud key (sources, preferences). `h` = horizon: tombstones
/// older than it were dropped.
struct CloudMapPayload<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var v = 1
    var h: Int64 = 0
    var items: [String: CloudEntry<Value>] = [:]
}

/// What this device knows about one synced key: change time and a hash of the value (nil = deleted).
struct KnownEntry: Codable, Equatable, Sendable {
    var at: Int64
    var hash: String?
}

/// A synced source – everything except secrets (iCloud Keychain) and device state (refresh status, account info).
struct CloudSourceRecord: Codable, Equatable, Sendable {
    var name: String
    var type: SourceType
    var host: String
    var epg: Bool
    var shift: Int
    var refresh: Int
    var created: Int64
    var sort: Int
    /// `SourceFingerprint` (a hash, no secret): the same panel/list added on two devices is one source.
    var fp: String?
}

/// Last-writer-wins merge of `CloudMapPayload`s against what this device knows (pure; unit-tested).
enum CloudMerge {
    static let dayMs: Int64 = 86_400_000

    /// Tombstones older than this are dropped (day granularity: two devices on the same day write the same value).
    static func horizon(now: Int64) -> Int64 { ((now - CloudSyncLimits.tombstoneTTLms) / dayMs) * dayMs }

    static func hash<V: Encodable>(_ value: V) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(Hashing.sha256Hex((try? encoder.encode(value)) ?? Data()).prefix(16))
    }

    /// Tie-break of two versions with the same time: deterministic on every device (a deletion wins).
    private static func rank(_ hash: String?) -> String { hash ?? "~" }

    /// Local changes since the last sync get the time `now` (strictly after their previous version); keys that are
    /// gone locally become tombstones. Returns true when something changed.
    @discardableResult
    static func stamp(current: [String: String], known: inout [String: KnownEntry], now: Int64) -> Bool {
        var changed = false
        for (key, hash) in current where known[key]?.hash != hash {
            known[key] = KnownEntry(at: max(now, (known[key]?.at ?? 0) + 1), hash: hash)
            changed = true
        }
        for (key, entry) in known where entry.hash != nil && current[key] == nil {
            known[key] = KnownEntry(at: max(now, entry.at + 1), hash: nil)
            changed = true
        }
        return changed
    }

    struct Outcome<V> {
        /// Remote versions to apply locally (nil = delete).
        var changes: [(key: String, value: V?)] = []
        var known: [String: KnownEntry]
        /// This device has versions the remote payload lacks (push).
        var localAhead = false
    }

    /// Remote payload → local. Newer remote versions win (`changes`); local versions newer than / missing in the
    /// remote mean `localAhead` – absence never deletes (another device may have overwritten the value without having
    /// seen ours). Only an expired local tombstone is forgotten.
    static func merge<V>(remote: CloudMapPayload<V>?, known input: [String: KnownEntry]) -> Outcome<V> {
        var out = Outcome<V>(known: input)
        guard let remote else {
            out.localAhead = !input.isEmpty
            return out
        }
        for (key, entry) in remote.items.sorted(by: { $0.key < $1.key }) {
            let remoteHash = entry.val.map { hash($0) }
            if let local = input[key] {
                if entry.at > local.at || (entry.at == local.at && rank(remoteHash) > rank(local.hash)) {
                    out.known[key] = KnownEntry(at: entry.at, hash: remoteHash)
                    out.changes.append((key, entry.val))
                } else if entry.at < local.at || remoteHash != local.hash {
                    out.localAhead = true
                }
            } else {
                out.known[key] = KnownEntry(at: entry.at, hash: remoteHash)
                if entry.val != nil { out.changes.append((key, entry.val)) }
            }
        }
        for (key, local) in input where remote.items[key] == nil {
            if local.hash == nil && local.at < remote.h {
                out.known[key] = nil   // tombstone expired everywhere
            } else {
                out.localAhead = true
            }
        }
        return out
    }

    /// The payload to write: live keys with their current value, tombstones newer than the horizon.
    static func payload<V>(known: [String: KnownEntry], current: [String: V], now: Int64) -> CloudMapPayload<V> {
        let h = horizon(now: now)
        var items: [String: CloudEntry<V>] = [:]
        for (key, entry) in known {
            if entry.hash != nil {
                if let value = current[key] { items[key] = CloudEntry(at: entry.at, val: value) }
            } else if entry.at >= h {
                items[key] = CloudEntry(at: entry.at, val: nil)
            }
        }
        return CloudMapPayload(h: h, items: items)
    }

    /// Drops expired tombstones from the local bookkeeping.
    static func compact(_ known: inout [String: KnownEntry], now: Int64) {
        let h = horizon(now: now)
        known = known.filter { $0.value.hash != nil || $0.value.at >= h }
    }
}

/// zlib-compressed JSON (all three iCloud values).
enum CloudCodec {
    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let json = try? encoder.encode(value) else { return nil }
        return try? (json as NSData).compressed(using: .zlib) as Data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data, let json = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: json)
    }
}

/// Favorites + the newest progress items + tombstones, as stored under `CloudSyncLimits.libraryKey`. Rows reuse
/// the compact positional encoding of the durable mirror (`DurableStateMirror.CompactItem`).
struct CloudLibraryPayload: Equatable, Sendable {
    var h: Int64 = 0
    /// False when favorites had to be left out to fit the budget (shown as "only the newest are synced").
    var full = true
    var favorites: [SyncItem] = []
    var progress: [SyncItem] = []
    /// Deleted favorites / progress (both kinds).
    var tombstones: [SyncItem] = []

    var all: [SyncItem] { favorites + progress + tombstones }

    /// key → (updatedAt, deleted): what two payloads are compared by.
    var versions: [String: CloudVersion] {
        Dictionary(all.map { ($0.key, CloudVersion(at: $0.updatedAt, deleted: $0.deleted)) }, uniquingKeysWith: { a, b in a.at >= b.at ? a : b })
    }
}

struct CloudVersion: Equatable, Sendable {
    var at: Int64
    var deleted: Bool
}

extension CloudLibraryPayload: Codable {
    private enum Keys: String, CodingKey { case v, h, full, fav, prog, del }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        h = try c.decodeIfPresent(Int64.self, forKey: .h) ?? 0
        full = try c.decodeIfPresent(Bool.self, forKey: .full) ?? true
        func items(_ key: Keys, _ kind: SyncKind) throws -> [SyncItem] {
            guard c.contains(key) else { return [] }
            var list = try c.nestedUnkeyedContainer(forKey: key)
            var out: [SyncItem] = []
            while !list.isAtEnd { out.append(try DurableStateMirror.CompactItem.decode(&list, kind: kind)) }
            return out
        }
        favorites = try items(.fav, .favorite)
        progress = try items(.prog, .progress)
        var dead: [SyncItem] = []
        if c.contains(.del) {
            var list = try c.nestedUnkeyedContainer(forKey: .del)
            while !list.isAtEnd {
                var row = try list.nestedUnkeyedContainer()
                let kind: SyncKind = try row.decode(String.self) == "p" ? .progress : .favorite
                let contentKey = try row.decode(String.self)
                let at = try row.decode(Int64.self)
                let key = kind == .favorite ? SyncItem.favoriteKey(contentKey) : SyncItem.progressKey(contentKey)
                dead.append(SyncItem(key: key, kind: kind, data: SyncItemData(title: "", contentKind: .live), updatedAt: at, deleted: true))
            }
        }
        tombstones = dead
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(1, forKey: .v)
        try c.encode(h, forKey: .h)
        try c.encode(full, forKey: .full)
        try c.encode(favorites.map(DurableStateMirror.CompactItem.init), forKey: .fav)
        try c.encode(progress.map(DurableStateMirror.CompactItem.init), forKey: .prog)
        var del = c.nestedUnkeyedContainer(forKey: .del)
        for item in tombstones {
            var row = del.nestedUnkeyedContainer()
            try row.encode(item.kind == .progress ? "p" : "f")
            try row.encode(item.contentKey)
            try row.encode(item.updatedAt)
        }
    }
}

/// Library side of the iCloud sync – runs off the main actor (database reads / LWW merge transaction).
enum CloudLibrarySync {
    /// Newest-first selection within the caps and `budget` bytes (compressed): progress is trimmed first (a quarter
    /// at a time), then favorites (the payload is then not `full`), then the oldest tombstones.
    static func payload(from items: [SyncItem], now: Int64, budget: Int) -> (payload: CloudLibraryPayload, data: Data?) {
        let h = CloudMerge.horizon(now: now)
        let newestFirst: (SyncItem, SyncItem) -> Bool = { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.key < $1.key }
        let liveFavorites = items.filter { $0.kind == .favorite && !$0.deleted }.sorted(by: newestFirst)
        var p = CloudLibraryPayload(h: h)
        p.favorites = Array(liveFavorites.prefix(CloudSyncLimits.maxFavorites))
        p.full = p.favorites.count == liveFavorites.count
        p.progress = Array(items.filter { $0.kind == .progress && !$0.deleted }.sorted(by: newestFirst).prefix(CloudSyncLimits.maxProgress))
        p.tombstones = Array(items.filter { $0.deleted && $0.updatedAt >= h }.sorted(by: newestFirst).prefix(CloudSyncLimits.maxTombstones))
        while true {
            guard let data = CloudCodec.encode(p) else { return (p, nil) }
            if data.count <= budget { return (p, data) }
            if !p.progress.isEmpty {
                p.progress.removeLast(max(1, p.progress.count / 4))
            } else if !p.favorites.isEmpty {
                p.favorites.removeLast(max(1, p.favorites.count / 4))
                p.full = false
            } else if !p.tombstones.isEmpty {
                p.tombstones.removeLast(max(1, p.tombstones.count / 4))
            } else {
                return (p, data)
            }
        }
    }

    struct MergeResult: Sendable {
        var applied = 0
        var localAhead = false
        var trimmed = false
    }

    /// Remote payload → library (LWW, ties keep the stored row; absence deletes nothing). `localAhead` when the
    /// payload this device would write now has versions the remote one lacks.
    static func merge(_ remote: CloudLibraryPayload?, into library: LibraryRepository, now: Int64, budget: Int) throws -> MergeResult {
        var result = MergeResult()
        if let remote { result.applied = try library.merge(remote.all).count }
        let mine = payload(from: try library.all(), now: now, budget: budget).payload
        result.trimmed = !mine.full
        guard let remote else {
            result.localAhead = !mine.all.isEmpty
            return result
        }
        let theirs = remote.versions
        result.localAhead = mine.versions.contains { key, version in theirs[key] != version }
        return result
    }
}
