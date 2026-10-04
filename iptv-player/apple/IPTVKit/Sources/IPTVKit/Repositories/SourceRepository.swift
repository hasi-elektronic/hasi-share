import Foundation
import IPTVCore

/// Source metadata (database) + secrets (secure store only, keyed by source id).
public final class SourceRepository: Sendable {
    private let database: AppDatabase
    private let secureStore: any SecureStore
    private var db: SQLiteDatabase { database.db }

    public init(database: AppDatabase, secureStore: any SecureStore) {
        self.database = database
        self.secureStore = secureStore
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
    }

    public func secrets(id: String) -> SourceSecrets? {
        secureStore.value(SourceSecrets.self, forKey: Self.secretsKey(id))
    }

    public func delete(id: String) throws {
        if let secrets = secrets(id: id) { Redactor.shared.unregister(secrets.redactableValues) }
        try secureStore.set(nil, forKey: Self.secretsKey(id))
        try db.run("DELETE FROM sources WHERE id = ?", [.text(id)])
    }

    /// Registers all stored secrets with the redactor (app start).
    public func registerSecretsForRedaction() {
        for source in (try? all()) ?? [] {
            if let s = secrets(id: source.id) { Redactor.shared.register(s.redactableValues) }
        }
    }
}
