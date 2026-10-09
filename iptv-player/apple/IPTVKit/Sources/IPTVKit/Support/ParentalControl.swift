import CommonCrypto
import Foundation
import IPTVCore
import Observation

/// Result of a PIN entry.
public enum PinCheck: Equatable, Sendable {
    case ok
    /// Wrong PIN; `remaining` attempts before the cooldown.
    case wrong(remaining: Int)
    /// Too many wrong PINs: no attempt is checked until `until`.
    case coolingDown(until: Date)
    /// No PIN is set.
    case noPin
}

/// Salted PBKDF2-HMAC-SHA256 of a 4-digit PIN (stored in the Keychain, never the PIN itself).
public struct PinHash: Codable, Sendable, Equatable {
    public var salt: Data
    public var hash: Data
    public var iterations: Int

    public static let defaultIterations = 60_000

    public static func make(pin: String, salt: Data? = nil, iterations: Int = defaultIterations) -> PinHash {
        let salt = salt ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        return PinHash(salt: salt, hash: derive(pin, salt: salt, iterations: iterations), iterations: iterations)
    }

    public func matches(_ pin: String) -> Bool {
        let candidate = Self.derive(pin, salt: salt, iterations: iterations)
        guard candidate.count == hash.count else { return false }
        return zip(candidate, hash).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0   // constant time
    }

    static func derive(_ pin: String, salt: Data, iterations: Int) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        let password = Array(pin.utf8).map { Int8(bitPattern: $0) }
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(max(1, iterations)), &out, out.count)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return Data(out)
    }
}

/// A request of the UI for the PIN (opening a locked category / channel, a protected settings page).
public struct PinPrompt: Identifiable, Sendable {
    public let id = UUID()
    public let reason: Reason
    public enum Reason: Sendable { case content, settings }
}

/// Parental control (docs/SCREENS.md §3.10): a 4-digit PIN (Keychain, PBKDF2), locked categories (live / movies /
/// series) and channels per source, "hide" vs "show with a lock", optional protection of Settings → sources and the
/// engine / calibration area, 5 wrong PINs → 1 min cooldown. A correct PIN unlocks the session until the app leaves
/// the foreground (`relock()`); while locked, `filter` is applied to every catalog query (`ContentLockFilter`).
@MainActor
@Observable
public final class ParentalControl {
    public static let pinKey = "parental.pin.v1"
    static let stateKey = "parental.state.v1"
    static let attemptsKey = "parental.attempts.v1"
    public static let maxAttempts = 5
    public static let cooldown: TimeInterval = 60

    struct State: Codable, Equatable {
        var hideLocked = true
        var protectSettings = true
        /// sourceId → kind raw value → category ids.
        var categories: [String: [String: [String]]] = [:]
        var channels: [String: [String]] = [:]
        /// The adult-category suggestion was offered for these sources.
        var suggested: [String] = []
    }

    struct Attempts: Codable, Equatable {
        var failures = 0
        var lockedUntil: Date?
    }

    @ObservationIgnored private let secureStore: any SecureStore
    @ObservationIgnored private let kv: any KeyValueStore
    @ObservationIgnored private let now: () -> Date
    private var state: State
    @ObservationIgnored private var attempts: Attempts
    public private(set) var hasPin: Bool
    /// The PIN was entered in this session (until `relock()`).
    public private(set) var isUnlocked = false
    /// Pending PIN request of the UI (the app root presents the pad).
    public private(set) var prompt: PinPrompt?
    @ObservationIgnored private var promptAction: (@MainActor () -> Void)?
    /// Called after every change that affects what the catalog shows (the environment re-applies the filter).
    @ObservationIgnored public var onChange: (() -> Void)?

    public init(secureStore: any SecureStore, kv: any KeyValueStore, now: @escaping () -> Date = Date.init) {
        self.secureStore = secureStore
        self.kv = kv
        self.now = now
        state = kv.value(State.self, forKey: Self.stateKey) ?? State()
        attempts = kv.value(Attempts.self, forKey: Self.attemptsKey) ?? Attempts()
        hasPin = secureStore.value(PinHash.self, forKey: Self.pinKey) != nil
    }

    // MARK: Settings

    /// Locked content is left out (true) or listed with a lock (false).
    public var hideLocked: Bool {
        get { state.hideLocked }
        set { update { $0.hideLocked = newValue } }
    }

    /// The PIN also protects Settings → sources / edit and the player engine / A/V calibration area.
    public var protectSettings: Bool {
        get { state.protectSettings }
        set { update { $0.protectSettings = newValue } }
    }

    /// Locks apply: a PIN exists and the session is not unlocked.
    public var isActive: Bool { hasPin && !isUnlocked }

    /// The filter the catalog applies now (nil while unlocked / without PIN).
    public var filter: ContentLockFilter? { isActive ? storedFilter : nil }

    /// The locks regardless of the session (Top Shelf / anything written for other processes must use this).
    public var storedFilter: ContentLockFilter {
        var categories: [String: [CategoryKind: Set<String>]] = [:]
        for (source, kinds) in state.categories {
            for (raw, ids) in kinds {
                if let kind = CategoryKind(rawValue: raw), !ids.isEmpty { categories[source, default: [:]][kind] = Set(ids) }
            }
        }
        return ContentLockFilter(categories: categories, channels: state.channels.mapValues(Set.init), hideLocked: state.hideLocked)
    }

    private func update(_ change: (inout State) -> Void) {
        var s = state
        change(&s)
        guard s != state else { return }
        state = s
        kv.setValue(s, forKey: Self.stateKey)
        onChange?()
    }

    // MARK: PIN

    public static func isValidPin(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Sets (or replaces) the PIN. Returns false for anything but 4 digits.
    @discardableResult
    public func setPin(_ pin: String) -> Bool {
        guard Self.isValidPin(pin) else { return false }
        do {
            try secureStore.setValue(PinHash.make(pin: pin), forKey: Self.pinKey)
        } catch {
            SafeLog.warning("parental: PIN not stored (\(type(of: error)))")
            return false
        }
        hasPin = true
        isUnlocked = true   // the one who set the PIN may go on; locks start with the next session / "Lock now"
        resetAttempts()
        onChange?()
        return true
    }

    /// Checks a PIN (with the 5-attempt cooldown).
    public func verify(_ pin: String) -> PinCheck {
        guard let stored = secureStore.value(PinHash.self, forKey: Self.pinKey) else { return .noPin }
        let t = now()
        if let until = attempts.lockedUntil {
            if t < until { return .coolingDown(until: until) }
            resetAttempts()
        }
        if stored.matches(pin) {
            resetAttempts()
            return .ok
        }
        attempts.failures += 1
        if attempts.failures >= Self.maxAttempts {
            let until = t.addingTimeInterval(Self.cooldown)
            attempts.lockedUntil = until
            saveAttempts()
            return .coolingDown(until: until)
        }
        saveAttempts()
        return .wrong(remaining: Self.maxAttempts - attempts.failures)
    }

    /// The cooldown in force now, if any.
    public var cooldownUntil: Date? {
        guard let until = attempts.lockedUntil, now() < until else { return nil }
        return until
    }

    /// PIN entry that unlocks the session.
    @discardableResult
    public func unlock(_ pin: String) -> PinCheck {
        let result = verify(pin)
        if result == .ok, !isUnlocked {
            isUnlocked = true
            onChange?()
        }
        return result
    }

    /// Back to locked (app left the foreground, "Lock now").
    public func relock() {
        guard isUnlocked else { return }
        isUnlocked = false
        onChange?()
    }

    @discardableResult
    public func changePin(old: String, new: String) -> PinCheck {
        guard Self.isValidPin(new) else { return .wrong(remaining: max(0, Self.maxAttempts - attempts.failures)) }
        let result = verify(old)
        if result == .ok { setPin(new) }
        return result
    }

    /// Removes the PIN (the lock lists stay and apply again once a new PIN is set).
    @discardableResult
    public func removePin(_ pin: String) -> PinCheck {
        let result = verify(pin)
        guard result == .ok else { return result }
        try? secureStore.set(nil, forKey: Self.pinKey)
        hasPin = false
        isUnlocked = false
        onChange?()
        return .ok
    }

    private func resetAttempts() {
        guard attempts != Attempts() else { return }
        attempts = Attempts()
        saveAttempts()
    }

    private func saveAttempts() { kv.setValue(attempts, forKey: Self.attemptsKey) }

    // MARK: Locks

    public func lockedCategoryIds(sourceId: String, kind: CategoryKind) -> Set<String> {
        Set(state.categories[sourceId]?[kind.rawValue] ?? [])
    }

    public func isCategoryLocked(_ categoryId: String?, kind: CategoryKind, sourceId: String) -> Bool {
        guard let categoryId else { return false }
        return state.categories[sourceId]?[kind.rawValue]?.contains(categoryId) ?? false
    }

    public func setCategoryLocked(_ locked: Bool, categoryId: String, kind: CategoryKind, sourceId: String) {
        update { s in
            var ids = s.categories[sourceId]?[kind.rawValue] ?? []
            ids.removeAll { $0 == categoryId }
            if locked { ids.append(categoryId) }
            s.categories[sourceId, default: [:]][kind.rawValue] = ids
        }
    }

    public func lockedChannelIds(sourceId: String) -> [String] { state.channels[sourceId] ?? [] }

    public func isChannelLocked(_ channelId: String, sourceId: String) -> Bool {
        state.channels[sourceId]?.contains(channelId) ?? false
    }

    public func setChannelLocked(_ locked: Bool, channelId: String, sourceId: String) {
        update { s in
            var ids = s.channels[sourceId] ?? []
            ids.removeAll { $0 == channelId }
            if locked { ids.append(channelId) }
            s.channels[sourceId] = ids
        }
    }

    /// Forgets the locks of a deleted source.
    public func removeAll(sourceId: String) {
        update { s in
            s.categories[sourceId] = nil
            s.channels[sourceId] = nil
            s.suggested.removeAll { $0 == sourceId }
        }
    }

    // MARK: Decisions

    /// Opening this category needs the PIN now.
    public func needsPin(categoryId: String?, kind: CategoryKind, sourceId: String) -> Bool {
        isActive && isCategoryLocked(categoryId, kind: kind, sourceId: sourceId)
    }

    /// Playing / opening this channel needs the PIN now (the channel or its category is locked).
    public func needsPin(channel: Channel) -> Bool {
        guard isActive else { return false }
        return isChannelLocked(channel.id, sourceId: channel.sourceId)
            || isCategoryLocked(channel.categoryId, kind: .live, sourceId: channel.sourceId)
    }

    /// Shows the lock mark on a listed category / channel (show-with-lock mode, still locked).
    public func showsLock(categoryId: String?, kind: CategoryKind, sourceId: String) -> Bool {
        needsPin(categoryId: categoryId, kind: kind, sourceId: sourceId)
    }

    /// Settings → sources / edit / engine need the PIN now.
    public var settingsNeedPin: Bool { hasPin && protectSettings && !isUnlocked }

    // MARK: Prompt

    /// Runs `action` at once when nothing is locked, otherwise asks the UI for the PIN first.
    public func requestUnlock(_ reason: PinPrompt.Reason = .content, then action: @escaping @MainActor () -> Void) {
        guard hasPin, !isUnlocked else {
            action()
            return
        }
        promptAction = action
        prompt = PinPrompt(reason: reason)
    }

    /// The pad was answered: unlocks with `pin` and closes the prompt on success; the pending action runs once the
    /// pad is gone (`promptDismissed()`, so a player cover is not presented while the pad is still dismissing).
    /// Returns the check result (the pad stays open for `.wrong` / `.coolingDown`).
    @discardableResult
    public func answerPrompt(_ pin: String) -> PinCheck {
        let result = unlock(pin)
        if result == .ok || result == .noPin {
            approvedAction = promptAction
            promptAction = nil
            prompt = nil
        }
        return result
    }

    @ObservationIgnored private var approvedAction: (@MainActor () -> Void)?

    /// The pad finished dismissing: runs the approved action (nothing after a cancel).
    public func promptDismissed() {
        let action = approvedAction
        approvedAction = nil
        promptAction = nil
        action?()
    }

    public func cancelPrompt() {
        promptAction = nil
        approvedAction = nil
        prompt = nil
    }

    // MARK: Adult categories

    /// Words that mark adult categories (case and diacritics folded; "18+" also as "+18").
    public nonisolated static let adultKeywords = ["xxx", "adult", "adults", "18+", "+18", "erotik", "erotic", "erotica", "yetişkin",
                                                   "yetiskin", "porn", "porno", "erwachsene", "for adults", "playboy", "hustler",
                                                   "brazzers", "redlight", "red light", "+21", "21+", "x-rated"]

    /// True when the category name looks like adult content.
    public nonisolated static func isAdultCategoryName(_ name: String) -> Bool {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ı", with: "i")
        // Word-ish matching: keyword surrounded by non-letters (so "Adultswim"/"Privatefernsehen" stay out).
        let letters = CharacterSet.letters
        for raw in adultKeywords {
            let keyword = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "ı", with: "i")
            var search = folded.startIndex..<folded.endIndex
            while let r = folded.range(of: keyword, range: search) {
                let beforeOK = r.lowerBound == folded.startIndex
                    || !(folded[folded.index(before: r.lowerBound)].unicodeScalars.first.map(letters.contains) ?? false)
                let afterOK = r.upperBound == folded.endIndex
                    || !(folded[r.upperBound].unicodeScalars.first.map(letters.contains) ?? false)
                if beforeOK && afterOK { return true }
                search = r.upperBound..<folded.endIndex
            }
        }
        return false
    }

    /// Categories of all kinds whose names look adult and that are not locked yet (first-PIN suggestion).
    public func adultSuggestions(sourceId: String, categories: [IPTVCore.Category]) -> [IPTVCore.Category] {
        categories.filter { Self.isAdultCategoryName($0.name) && !isCategoryLocked($0.id, kind: $0.kind, sourceId: sourceId) }
    }

    public func wasSuggestionOffered(sourceId: String) -> Bool { state.suggested.contains(sourceId) }

    public func markSuggestionOffered(sourceId: String) {
        update { if !$0.suggested.contains(sourceId) { $0.suggested.append(sourceId) } }
    }
}
