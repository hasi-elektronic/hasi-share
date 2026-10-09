import Foundation
import IPTVCore
import Observation

/// A synced preference: a name (e.g. `catnav.pin.movie`) and, for per-source preferences, the local source id.
public struct CloudPreferenceKey: Hashable, Sendable {
    public var name: String
    public var sourceId: String?
    public init(_ name: String, sourceId: String? = nil) {
        self.name = name
        self.sourceId = sourceId
    }
}

/// Something that owns synced preferences (category pins/hidden, favorite order, hidden live channels). Values are
/// string lists; an empty list = nothing set.
@MainActor
public protocol CloudPreferenceProvider: AnyObject {
    /// The preference names this provider owns.
    var cloudPreferenceNames: Set<String> { get }
    /// Current values (empty ones may be omitted).
    func cloudPreferences() -> [CloudPreferenceKey: [String]]
    /// Values from another device (`[]` = cleared there).
    func applyCloudPreferences(_ values: [CloudPreferenceKey: [String]])
}

/// iCloud sync between the user's devices (Build 17, docs/ARCHITECTURE.md §6.1) – no backend account needed.
///
/// - **Where:** `NSUbiquitousKeyValueStore` (3 keys, < 1 MB) for sources without secrets, favorites, the 300 newest
///   progress items, category pins/hidden/country, favorite order and hidden live channels; the source secrets go
///   to iCloud Keychain (`CloudSecretStore`, synchronizable items). Audio delays / VLC calibration, the selected
///   source and recent searches stay on the device.
/// - **Merge:** last-writer-wins per item by change time (`SyncItem.updatedAt` for the library, `CloudMerge` stamps
///   for sources/preferences), tombstones for deletions (90 days, `CloudSyncLimits.tombstoneTTLms`). Every write
///   first merges what other devices wrote; a device that finds itself ahead of the remote writes again – the
///   devices converge even when two of them overwrite the same key at once.
/// - **Same source on two devices** (added before sync was on): one source by fingerprint; the smaller cloud id
///   wins, the other device maps its local source onto it.
/// - **Timing:** local changes are written ≥ 2 s after the first change and at most once per `pushInterval`
///   (coalesced), and when the app goes to the background; remote changes are applied on the main actor, the
///   library merge runs off it.
@MainActor
@Observable
public final class CloudSync {
    public enum Status: Equatable, Sendable {
        case off, noAccount, syncing, upToDate, storageFull
    }

    public private(set) var isEnabled = false
    public private(set) var accountAvailable: Bool
    public private(set) var isSyncing = false
    public private(set) var lastSyncedAt: Date?
    /// Sources received from another device whose secrets have not arrived through iCloud Keychain yet.
    public private(set) var awaitingSecrets: Set<String> = []
    /// iCloud reported a quota violation: the library is written with a smaller budget (older progress not synced).
    public private(set) var storageFull = false
    /// Favorites were left out to stay within the budget (only the newest are synced).
    public private(set) var libraryTrimmed = false

    public var status: Status {
        if !isEnabled { return .off }
        if !accountAvailable { return .noAccount }
        if isSyncing && lastSyncedAt == nil { return .syncing }
        if storageFull { return .storageFull }
        return .upToDate
    }

    @ObservationIgnored private let store: any CloudKeyValueStore
    @ObservationIgnored private let account: any CloudAccountProvider
    @ObservationIgnored private let kv: any KeyValueStore
    @ObservationIgnored weak var env: AppEnvironment?
    @ObservationIgnored public var preferenceProviders: [any CloudPreferenceProvider] = []
    /// Minimum time between two writes of local changes.
    @ObservationIgnored public var pushInterval: TimeInterval = 5
    /// Local changes are collected this long before they are written.
    @ObservationIgnored public var pushDelay: TimeInterval = 2
    @ObservationIgnored public var secretPollInterval: Duration = .seconds(15)
    @ObservationIgnored public var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    @ObservationIgnored private var state: LocalState
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var pushScheduled = false
    @ObservationIgnored private var lastPush: Date = .distantPast
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var activated = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Remote bytes this device last merged or wrote, per key (unchanged values are not merged again).
    @ObservationIgnored private var lastSeen: [String: Data] = [:]

    static let enabledKey = "icloud.enabled"
    static let stateKey = "icloud.state.v1"
    private static let keys = [CloudSyncLimits.sourcesKey, CloudSyncLimits.prefsKey, CloudSyncLimits.libraryKey]

    /// Device-local bookkeeping (UserDefaults, never synced).
    struct LocalState: Codable, Equatable {
        var sources: [String: KnownEntry] = [:]
        var prefs: [String: KnownEntry] = [:]
        /// Local source id → cloud id, when they differ (the same source was added on two devices).
        var cloudIds: [String: String] = [:]
        /// Fingerprints of sources that came from iCloud (their secrets may not be here yet).
        var fingerprints: [String: String] = [:]
        var lastMergeAt: Int64?
        /// Lowered library budget after a quota violation.
        var libraryBudget: Int?
    }

    public init(store: any CloudKeyValueStore, account: any CloudAccountProvider, kv: any KeyValueStore) {
        self.store = store
        self.account = account
        self.kv = kv
        accountAvailable = account.isAvailable
        state = kv.value(LocalState.self, forKey: Self.stateKey) ?? LocalState()
        storageFull = state.libraryBudget != nil
    }

    /// The user's choice; nil = never chosen (on while an iCloud account is available).
    public var storedPreference: Bool? { kv.value(Bool.self, forKey: Self.enabledKey) }

    // MARK: Lifecycle

    /// Starts observing and – when sync is on – merges and writes once. Call after every preference provider is
    /// registered (the app: `AppBootstrap`).
    public func activate() {
        guard !activated else { return }
        activated = true
        store.observe { [weak self] change, keys in
            Task { @MainActor in self?.externalChange(change, keys: keys) }
        }
        account.observe { [weak self] in
            Task { @MainActor in self?.accountChanged() }
        }
        accountAvailable = account.isAvailable
        refreshAwaitingSecrets()
        if storedPreference ?? accountAvailable { start() }
    }

    /// Settings toggle "Sync with iCloud".
    public func setEnabled(_ on: Bool) {
        kv.setValue(on, forKey: Self.enabledKey)
        guard on != isEnabled else { return }
        if on { start() } else { stop() }
    }

    private func start() {
        isEnabled = true
        if let repo = env?.sourceRepository {
            repo.synchronizeSecrets = true
            repo.convertSecrets(toSynchronizable: true)   // first enable: existing secrets move to iCloud Keychain
        }
        store.synchronize()
        stampLocal()
        enqueue { await self.sync(pushLocal: true) }
    }

    /// Off: nothing is written or applied any more; every local item stays. Secrets get a device-only copy again
    /// (the iCloud Keychain copies stay for the other devices).
    private func stop() {
        isEnabled = false
        if let repo = env?.sourceRepository {
            repo.synchronizeSecrets = false
            repo.convertSecrets(toSynchronizable: false)
        }
        saveState()
    }

    /// A favorite / progress / source / preference changed on this device.
    public func noteLocalChange() {
        guard isEnabled, !applying else { return }
        stampLocal()
        schedulePush()
    }

    /// Back in the foreground: fetch what other devices wrote; secrets that arrived meanwhile start their sources.
    public func appBecameActive() {
        checkAwaitingSecrets()
        guard isEnabled else { return }
        store.synchronize()
        enqueue { await self.sync(pushLocal: false) }
    }

    /// Going to the background: pending local changes are written now.
    public func flush() {
        guard isEnabled else { return }
        enqueue { await self.sync(pushLocal: true) }
    }

    /// Merge + write now and wait (tests, pull to refresh).
    public func syncNow() async {
        if isEnabled { enqueue { await self.sync(pushLocal: true) } }
        await waitForIdle()
    }

    /// Waits until queued sync work is done (tests).
    public func waitForIdle() async {
        var last: Task<Void, Never>?
        repeat {
            last = chain
            await last?.value
        } while chain != last
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func schedulePush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        let delay = max(pushDelay, lastPush.addingTimeInterval(pushInterval).timeIntervalSinceNow)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.pushScheduled = false
            self.enqueue { await self.sync(pushLocal: true) }
        }
    }

    private func externalChange(_ change: CloudStoreChange, keys: [String]) {
        guard isEnabled else { return }
        switch change {
        case .quotaViolation:
            let current = state.libraryBudget ?? CloudSyncLimits.libraryBudgetBytes
            guard current > CloudSyncLimits.minLibraryBudgetBytes else { return }
            state.libraryBudget = max(CloudSyncLimits.minLibraryBudgetBytes, current / 2)
            storageFull = true
            saveState()
            SafeLog.warning("icloud: quota exceeded, library budget \(state.libraryBudget ?? 0) bytes")
            enqueue { await self.sync(pushLocal: true) }
        case .accountChange:
            // Another Apple ID: its data is not "what this device last merged" – start over like a first enable.
            state.sources = [:]
            state.prefs = [:]
            state.lastMergeAt = nil
            lastSeen = [:]
            stampLocal()
            enqueue { await self.sync(pushLocal: true) }
        case .serverChange, .initialSync:
            enqueue { await self.sync(pushLocal: false) }
        }
    }

    private func accountChanged() {
        let was = accountAvailable
        accountAvailable = account.isAvailable
        if storedPreference == nil {
            if accountAvailable && !isEnabled { start() } else if !accountAvailable && isEnabled { stop() }
        } else if accountAvailable && !was && isEnabled {
            enqueue { await self.sync(pushLocal: true) }
        }
    }

    // MARK: Sync

    private func sync(pushLocal: Bool) async {
        guard isEnabled, env != nil else { return }
        isSyncing = true
        defer { isSyncing = false }
        stampLocal()
        var remote: [String: Data] = [:]
        for key in Self.keys { remote[key] = store.data(forKey: key) }
        var ahead = false
        if state.lastMergeAt == nil || Self.keys.contains(where: { remote[$0] != lastSeen[$0] }) {
            ahead = await merge(remote)
            guard isEnabled else { return }
        }
        if pushLocal || ahead { await write(remote) }
        lastSyncedAt = Date()
        saveState()
    }

    /// Applies what other devices wrote. Returns true when this device has versions the remote lacks.
    private func merge(_ remote: [String: Data]) async -> Bool {
        guard let env else { return false }
        let nowMs = now()
        applying = true
        let remoteSources = CloudCodec.decode(CloudMapPayload<CloudSourceRecord>.self, from: remote[CloudSyncLimits.sourcesKey])
        let sourcesOutcome = CloudMerge.merge(remote: remoteSources, known: state.sources)
        state.sources = sourcesOutcome.known
        let dedupeAhead = applySources(sourcesOutcome.changes, remote: remoteSources, now: nowMs)
        let remotePrefs = CloudCodec.decode(CloudMapPayload<[String]>.self, from: remote[CloudSyncLimits.prefsKey])
        let prefsOutcome = CloudMerge.merge(remote: remotePrefs, known: state.prefs)
        state.prefs = prefsOutcome.known
        applyPrefs(prefsOutcome.changes)
        applying = false

        let library = env.library, writes = env.database.deferredWrites
        let budget = libraryBudget
        let remoteLibrary = CloudCodec.decode(CloudLibraryPayload.self, from: remote[CloudSyncLimits.libraryKey])
        let result = await Task.detached(priority: .utility) { () -> CloudLibrarySync.MergeResult? in
            if library.hasPendingWrites { _ = writes.drain(timeout: 2) }
            do {
                return try CloudLibrarySync.merge(remoteLibrary, into: library, now: nowMs, budget: budget)
            } catch {
                SafeLog.warning("icloud: library merge failed")
                return nil
            }
        }.value
        if let result {
            libraryTrimmed = result.trimmed
            if result.applied > 0 {
                applying = true
                env.favorites.reload()
                env.cloudLibraryChanged()
                applying = false
            }
        }
        state.lastMergeAt = nowMs
        lastSeen = remote
        CloudMerge.compact(&state.sources, now: nowMs)
        CloudMerge.compact(&state.prefs, now: nowMs)
        return sourcesOutcome.localAhead || dedupeAhead || prefsOutcome.localAhead || result?.localAhead == true
    }

    private var libraryBudget: Int { state.libraryBudget ?? CloudSyncLimits.libraryBudgetBytes }

    /// Writes this device's view of every domain whose content differs from the remote one.
    private func write(_ remote: [String: Data]) async {
        guard let env else { return }
        let nowMs = now()
        stampLocal()
        let sources = CloudMerge.payload(known: state.sources, current: currentSources(), now: nowMs)
        if sources.items != CloudCodec.decode(CloudMapPayload<CloudSourceRecord>.self, from: remote[CloudSyncLimits.sourcesKey])?.items ?? [:] {
            put(CloudCodec.encode(sources), key: CloudSyncLimits.sourcesKey, budget: CloudSyncLimits.sourcesBudgetBytes)
        }
        let prefs = CloudMerge.payload(known: state.prefs, current: currentPrefs(), now: nowMs)
        if prefs.items != CloudCodec.decode(CloudMapPayload<[String]>.self, from: remote[CloudSyncLimits.prefsKey])?.items ?? [:] {
            put(CloudCodec.encode(prefs), key: CloudSyncLimits.prefsKey, budget: CloudSyncLimits.prefsBudgetBytes)
        }
        let library = env.library, writes = env.database.deferredWrites, budget = libraryBudget
        let built = await Task.detached(priority: .utility) { () -> (CloudLibraryPayload, Data?)? in
            if library.hasPendingWrites { _ = writes.drain(timeout: 2) }
            guard let items = try? library.all() else { return nil }
            let built = CloudLibrarySync.payload(from: items, now: nowMs, budget: budget)
            return (built.payload, built.data)
        }.value
        if let (payload, data) = built {
            libraryTrimmed = !payload.full
            if payload.versions != CloudCodec.decode(CloudLibraryPayload.self, from: remote[CloudSyncLimits.libraryKey])?.versions ?? [:] {
                put(data, key: CloudSyncLimits.libraryKey, budget: budget)
            }
        }
        store.synchronize()
        lastPush = Date()
    }

    private func put(_ data: Data?, key: String, budget: Int) {
        guard let data else { return }
        guard data.count <= budget else {
            SafeLog.warning("icloud: \(key) is \(data.count) bytes (budget \(budget)), not written")
            return
        }
        store.set(data, forKey: key)
        if store.data(forKey: key) == data { lastSeen[key] = data }
    }

    private func saveState() {
        kv.setValue(state, forKey: Self.stateKey)
    }

    // MARK: Sources

    private func cloudId(_ localId: String) -> String { state.cloudIds[localId] ?? localId }

    private func localId(forCloud cloudId: String) -> String? {
        env?.sources.first { self.cloudId($0.id) == cloudId }?.id
    }

    private func fingerprint(_ localId: String) -> String? {
        env?.fingerprint(sourceId: localId) ?? state.fingerprints[localId]
    }

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// Synced view of the local sources, by cloud id. A source that was just added and never loaded is left out
    /// until its first refresh (a failed add removes it again).
    private func currentSources() -> [String: CloudSourceRecord] {
        guard let env else { return [:] }
        var out: [String: CloudSourceRecord] = [:]
        for (index, source) in env.sources.enumerated() {
            let cid = cloudId(source.id)
            guard source.lastRefreshResult != nil || state.sources[cid] != nil || state.fingerprints[source.id] != nil else { continue }
            out[cid] = CloudSourceRecord(name: source.name, type: source.type, host: source.displayHost, epg: source.epgUrlOverride,
                                         shift: source.epgShiftMinutes, refresh: source.autoRefreshHours,
                                         created: Self.ms(source.createdAt), sort: index, fp: fingerprint(source.id))
        }
        return out
    }

    private static func source(_ record: CloudSourceRecord, id: String) -> Source {
        Source(id: id, name: record.name, type: record.type, displayHost: record.host, epgUrlOverride: record.epg,
               epgShiftMinutes: record.shift, autoRefreshHours: record.refresh,
               createdAt: Date(timeIntervalSince1970: Double(record.created) / 1000))
    }

    /// Remote source versions → database. Returns true when a duplicate was resolved (the result must be written).
    private func applySources(_ changes: [(key: String, value: CloudSourceRecord?)], remote: CloudMapPayload<CloudSourceRecord>?,
                              now nowMs: Int64) -> Bool {
        guard let env, !changes.isEmpty else { return false }
        var ahead = false
        var refresh: [String] = []
        var touched = false
        for (cid, record) in changes {
            guard let record else { continue }
            touched = true
            if let lid = localId(forCloud: cid) {
                let before = env.sources.first { $0.id == lid }
                try? env.sourceRepository.upsertFromCloud(Self.source(record, id: lid))
                if before?.displayHost != record.host || before?.type != record.type, env.secrets(for: lid) != nil { refresh.append(lid) }
            } else if let fp = record.fp, let match = env.sources.first(where: { fingerprint($0.id) == fp }) {
                // The same panel / list was added on two devices: one source, the smaller cloud id.
                let current = cloudId(match.id)
                ahead = true
                if cid < current {
                    state.cloudIds[match.id] = cid == match.id ? nil : cid
                    if let old = state.sources[current], old.hash != nil {
                        state.sources[current] = KnownEntry(at: max(nowMs, old.at + 1), hash: nil)
                    }
                    try? env.sourceRepository.upsertFromCloud(Self.source(record, id: match.id))
                } else {
                    let at = remote?.items[cid]?.at ?? 0
                    state.sources[cid] = KnownEntry(at: max(nowMs, at + 1), hash: nil)
                }
            } else {
                try? env.sourceRepository.upsertFromCloud(Self.source(record, id: cid))
                if let fp = record.fp { state.fingerprints[cid] = fp }
                if env.secrets(for: cid) != nil { refresh.append(cid) } else { awaitingSecrets.insert(cid) }
            }
        }
        for (cid, record) in changes where record == nil {
            guard let lid = localId(forCloud: cid) else { continue }
            env.deleteSource(id: lid)
            state.cloudIds[lid] = nil
            state.fingerprints[lid] = nil
            awaitingSecrets.remove(lid)
            touched = true
        }
        guard touched else { return ahead }
        env.reloadSources()
        // Order: the winning remote versions bring their position, the others keep theirs.
        if let remote {
            let ids = env.sources.map(\.id)
            func position(_ index: Int, _ id: String) -> (Int, Int) {
                let cid = cloudId(id)
                if let entry = remote.items[cid], let value = entry.val, state.sources[cid]?.hash == CloudMerge.hash(value) {
                    return (value.sort, index)
                }
                return (index, index)
            }
            let ordered = ids.enumerated().sorted { position($0.offset, $0.element) < position($1.offset, $1.element) }.map(\.element)
            if ordered != ids {
                try? env.sourceRepository.reorder(ordered)
                env.reloadSources()
            }
        }
        env.refreshInBackground(refresh)
        startPollingIfNeeded()
        return ahead
    }

    // MARK: Secrets not yet in iCloud Keychain

    private func refreshAwaitingSecrets() {
        guard let env else { return }
        awaitingSecrets = Set(env.sources.filter {
            state.fingerprints[$0.id] != nil && $0.lastRefreshResult == nil && env.secrets(for: $0.id) == nil
        }.map(\.id))
        startPollingIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard !awaitingSecrets.isEmpty, pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while true {
                guard let interval = self?.secretPollInterval else { return }
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.checkAwaitingSecrets()
                if self.awaitingSecrets.isEmpty {
                    self.pollTask = nil
                    return
                }
            }
        }
    }

    /// Sources whose secrets arrived through iCloud Keychain are loaded now.
    public func checkAwaitingSecrets() {
        guard let env, !awaitingSecrets.isEmpty else { return }
        awaitingSecrets.formIntersection(env.sources.map(\.id))
        let ready = awaitingSecrets.filter { env.secrets(for: $0) != nil }
        guard !ready.isEmpty else { return }
        awaitingSecrets.subtract(ready)
        env.refreshInBackground(env.sources.map(\.id).filter(ready.contains))
    }

    // MARK: Preferences

    private static let separator = "@"

    /// Synced preferences by cloud key (`name` or `name@cloudSourceId`); only of sources that are synced.
    private func currentPrefs() -> [String: [String]] {
        guard let env else { return [:] }
        let synced = Set(currentSources().keys)
        var out: [String: [String]] = [:]
        for provider in preferenceProviders {
            for (key, value) in provider.cloudPreferences() where !value.isEmpty {
                if let sid = key.sourceId {
                    guard env.sources.contains(where: { $0.id == sid }) else { continue }
                    let cid = cloudId(sid)
                    guard synced.contains(cid) else { continue }
                    out[key.name + Self.separator + cid] = value
                } else {
                    out[key.name] = value
                }
            }
        }
        return out
    }

    private func applyPrefs(_ changes: [(key: String, value: [String]?)]) {
        guard !changes.isEmpty else { return }
        var batches: [ObjectIdentifier: [CloudPreferenceKey: [String]]] = [:]
        for (cloudKey, value) in changes {
            let parts = cloudKey.split(separator: Character(Self.separator), maxSplits: 1).map(String.init)
            let name = parts[0]
            var localSource: String?
            if parts.count == 2 {
                guard let lid = localId(forCloud: parts[1]) else {
                    state.prefs[cloudKey] = nil   // its source is not here (yet): applied once it is
                    continue
                }
                localSource = lid
            }
            guard let provider = preferenceProviders.first(where: { $0.cloudPreferenceNames.contains(name) }) else {
                state.prefs[cloudKey] = nil
                continue
            }
            batches[ObjectIdentifier(provider), default: [:]][CloudPreferenceKey(name, sourceId: localSource)] = value ?? []
        }
        for provider in preferenceProviders {
            if let batch = batches[ObjectIdentifier(provider)] { provider.applyCloudPreferences(batch) }
        }
    }

    /// Local changes since the last sync get their change time.
    private func stampLocal() {
        guard isEnabled, env != nil else { return }
        let nowMs = now()
        CloudMerge.stamp(current: currentSources().mapValues { CloudMerge.hash($0) }, known: &state.sources, now: nowMs)
        CloudMerge.stamp(current: currentPrefs().mapValues { CloudMerge.hash($0) }, known: &state.prefs, now: nowMs)
    }
}
