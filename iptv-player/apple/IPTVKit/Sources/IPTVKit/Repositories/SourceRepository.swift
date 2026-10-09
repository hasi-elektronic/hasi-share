import Foundation
import IPTVCore

/// Source metadata (database) + secrets (secure store only, keyed by source id).
public final class SourceRepository: Sendable {
    private let database: AppDatabase
    private let secureStore: any SecureStore
    /// Persistent copy of the source list (survives a purged database, `DurableStateMirror`).
    private let mirror: DurableStateMirror?
    private var db: SQLiteDatabase { database.db }
    private let syncFlag = LockedFlag()

    /// iCloud sync on (`CloudSync`): secrets are written as iCloud Keychain items and a delete removes them on every
    /// device. Off: device-only items; a delete leaves an iCloud copy to the user's other devices.
    public var synchronizeSecrets: Bool {
        get { syncFlag.value }
        set { syncFlag.value = newValue }
    }

    public init(database: AppDatabase, secureStore: any SecureStore, mirror: DurableStateMirror? = nil) {
        self.database = database
        self.secureStore = secureStore
        self.mirror = mirror
    }

    /// Writes the current list into the mirror (after every change; a failed read leaves the mirror as it is).
    public func updateMirror() {
        guard let mirror, let list = try? all() else { return }
        mirror.recordSources(list)
    }

    static func secretsKey(_ id: String) -> String { "source.secrets.\(id)" }

    private func writeSecrets(_ secrets: SourceSecrets?, id: String) throws {
        let data = try secrets.map { try JSONEncoder().encode($0) }
        if let cloud = secureStore as? any CloudSecretStore {
            try cloud.set(data, forKey: Self.secretsKey(id), synchronizable: synchronizeSecrets)
        } else {
            try secureStore.set(data, forKey: Self.secretsKey(id))
        }
    }

    /// Moves the secrets of every source into iCloud Keychain (`true`) or copies them back to device-only items
    /// (`false`; the iCloud copies stay for the other devices). Returns the number of failed conversions.
    @discardableResult
    public func convertSecrets(toSynchronizable on: Bool) -> Int {
        guard let cloud = secureStore as? any CloudSecretStore else { return 0 }
        var failed = 0
        for source in (try? all()) ?? [] {
            do { try cloud.convert(key: Self.secretsKey(source.id), toSynchronizable: on) } catch { failed += 1 }
        }
        if failed > 0 { SafeLog.warning("keychain: \(failed) source secrets not converted (synchronizable: \(on))") }
        return failed
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public func all() throws -> [Source] {
        try db.query("SELECT json FROM sources ORDER BY sort, rowid") {
            try Self.decoder.decode(Source.self, from: Data($0.string(0).utf8))
        }
    }

    public func source(id: String) throws -> Source? {
        try db.queryFirst("SELECT json FROM sources WHERE id = ?", [.text(id)]) {
            try Self.decoder.decode(Source.self, from: Data($0.string(0).utf8))
        }
    }

    /// Inserts or updates a source; secrets (if given) go to the secure store and are
    /// registered with the log redactor.
    public func save(_ source: Source, secrets: SourceSecrets? = nil) throws {
        if let secrets {
            try writeSecrets(secrets, id: source.id)
            Redactor.shared.register(secrets.redactableValues)
        }
        let json = String(decoding: try Self.encoder.encode(source), as: UTF8.self)
        let sort = try db.queryFirst("SELECT sort FROM sources WHERE id = ?", [.text(source.id)]) { $0.int(0) }
            ?? (try db.scalar("SELECT COALESCE(MAX(sort), -1) + 1 FROM sources"))
        try db.run("INSERT INTO sources (id, sort, json) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                   [.text(source.id), .from(sort), .text(json)])
        updateMirror()
    }

    /// Atomic read-modify-write of a stored source (refresh results, EPG status): concurrent writers (a catalog
    /// refresh, an EPG load, a settings change) never overwrite each other's fields with a stale copy.
    /// Returns the updated source (nil when it no longer exists).
    @discardableResult
    public func update(id: String, _ change: (inout Source) -> Void) throws -> Source? {
        let updated: Source? = try db.transaction {
            guard var source = try self.source(id: id) else { return nil }
            change(&source)
            let json = String(decoding: try Self.encoder.encode(source), as: UTF8.self)
            try db.run("UPDATE sources SET json = ? WHERE id = ?", [.text(json), .text(id)])
            return source
        }
        if updated != nil { updateMirror() }
        return updated
    }

    /// New order of the sources (ids not listed keep their place after the listed ones).
    public func reorder(_ ids: [String]) throws {
        try db.transaction {
            let rest = try all().map(\.id).filter { !ids.contains($0) }
            for (index, id) in (ids + rest).enumerated() {
                try db.run("UPDATE sources SET sort = ? WHERE id = ?", [.from(index), .text(id)])
            }
        }
        updateMirror()
    }

    /// Re-inserts mirrored sources (same ids, order = list order) without touching their secrets.
    func restore(_ sources: [Source]) throws {
        try db.transaction {
            for (index, source) in sources.enumerated() {
                let json = String(decoding: try Self.encoder.encode(source), as: UTF8.self)
                try db.run("INSERT OR IGNORE INTO sources (id, sort, json) VALUES (?,?,?)",
                           [.text(source.id), .from(index), .text(json)])
            }
        }
        updateMirror()
    }

    /// A source that arrived through iCloud sync (`CloudSync`): inserted (at the end) when its id is new, else its
    /// synced fields (name, type, host, EPG settings, auto refresh, creation time) are updated – the local refresh
    /// status stays.
    func upsertFromCloud(_ source: Source) throws {
        if try self.source(id: source.id) == nil {
            let json = String(decoding: try Self.encoder.encode(source), as: UTF8.self)
            try db.run("INSERT OR IGNORE INTO sources (id, sort, json) VALUES (?, (SELECT COALESCE(MAX(sort), -1) + 1 FROM sources), ?)",
                       [.text(source.id), .text(json)])
            updateMirror()
        } else {
            try update(id: source.id) { local in
                local.name = source.name
                local.type = source.type
                local.displayHost = source.displayHost
                local.epgUrlOverride = source.epgUrlOverride
                local.epgShiftMinutes = source.epgShiftMinutes
                local.autoRefreshHours = source.autoRefreshHours
                local.createdAt = source.createdAt
            }
        }
    }

    public func secrets(id: String) -> SourceSecrets? {
        secureStore.value(SourceSecrets.self, forKey: Self.secretsKey(id))
    }

    public func delete(id: String) throws {
        if let secrets = secrets(id: id) { Redactor.shared.unregister(secrets.redactableValues) }
        try writeSecrets(nil, id: id)
        try db.run("DELETE FROM sources WHERE id = ?", [.text(id)])
        updateMirror()
    }

    /// Registers all stored secrets with the redactor (app start).
    public func registerSecretsForRedaction() {
        for source in (try? all()) ?? [] {
            if let s = secrets(id: source.id) { Redactor.shared.register(s.redactableValues) }
        }
    }
}
