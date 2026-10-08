import Foundation
import IPTVCore

/// Source metadata (database) + secrets (secure store only, keyed by source id).
public final class SourceRepository: Sendable {
    private let database: AppDatabase
    private let secureStore: any SecureStore
    /// Persistent copy of the source list (survives a purged database, `DurableStateMirror`).
    private let mirror: DurableStateMirror?
    private var db: SQLiteDatabase { database.db }

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

    private static func secretsKey(_ id: String) -> String { "source.secrets.\(id)" }

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
            try secureStore.setValue(secrets, forKey: Self.secretsKey(source.id))
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

    public func secrets(id: String) -> SourceSecrets? {
        secureStore.value(SourceSecrets.self, forKey: Self.secretsKey(id))
    }

    public func delete(id: String) throws {
        if let secrets = secrets(id: id) { Redactor.shared.unregister(secrets.redactableValues) }
        try secureStore.set(nil, forKey: Self.secretsKey(id))
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
