import Foundation
import IPTVCore
import Observation

/// A programme reminder (docs/SCREENS.md §3.4 "Erinnern"): local, survives relaunch, removed after the programme.
public struct ProgramReminder: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var sourceId: String
    public var channelId: String
    public var channelName: String
    public var title: String
    public var start: Date
    public var end: Date

    public init(sourceId: String, channelId: String, channelName: String, title: String, start: Date, end: Date) {
        self.id = Self.id(sourceId: sourceId, channelId: channelId, start: start)
        self.sourceId = sourceId
        self.channelId = channelId
        self.channelName = channelName
        self.title = title
        self.start = start
        self.end = end
    }

    public static func id(sourceId: String, channelId: String, start: Date) -> String {
        "\(sourceId)|\(channelId)|\(Int64(start.timeIntervalSince1970))"
    }
}

/// One moment a reminder announces itself: at the start, or `leadMinutes` before it.
public struct ReminderFire: Sendable, Hashable {
    public var reminder: ProgramReminder
    public var date: Date
    /// Minutes before the start (0 = "starts now").
    public var minutesBefore: Int
    public var key: String { "\(reminder.id)#\(minutesBefore)" }
}

/// System notifications of reminders (iOS: `UNUserNotificationCenter`; tvOS has no alerts – the in-app banner only).
@MainActor
public protocol ReminderNotifier: AnyObject {
    /// Asks for permission once (first reminder); false = denied (the in-app banner still works).
    func requestAuthorization() async -> Bool
    func schedule(_ fires: [ReminderFire])
    func cancel(reminderIds: [String])
}

/// Programme reminders: stored in the key-value store (survive relaunch), system notifications through the
/// notifier, the in-app banner (`dueFires`) while the app is open, cleanup once the programme has ended.
@MainActor
@Observable
public final class ReminderStore {
    static let key = "reminders.v1"
    static let leadKey = "reminders.lead"
    static let autoSwitchKey = "reminders.autoSwitch"
    /// The 5-minute warning.
    public static let leadMinutesOption = 5

    public private(set) var reminders: [ProgramReminder] = []
    /// Also remind `leadMinutesOption` minutes before the start.
    public var remindEarly: Bool {
        didSet {
            guard remindEarly != oldValue else { return }
            kv.setValue(remindEarly, forKey: Self.leadKey)
            reschedule()
        }
    }
    /// At the start, switch to the channel by itself (the banner then only tells).
    public var autoSwitch: Bool {
        didSet { if autoSwitch != oldValue { kv.setValue(autoSwitch, forKey: Self.autoSwitchKey) } }
    }
    @ObservationIgnored public weak var notifier: (any ReminderNotifier)?
    @ObservationIgnored private let kv: any KeyValueStore
    @ObservationIgnored private let now: () -> Date
    /// Fire keys already shown in the app (not persisted: a relaunch after a missed start shows nothing old).
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var askedPermission = false

    public init(kv: any KeyValueStore, now: @escaping () -> Date = Date.init) {
        self.kv = kv
        self.now = now
        remindEarly = kv.value(Bool.self, forKey: Self.leadKey) ?? false
        autoSwitch = kv.value(Bool.self, forKey: Self.autoSwitchKey) ?? false
        reminders = (kv.value([ProgramReminder].self, forKey: Self.key) ?? []).sorted { $0.start < $1.start }
        cleanup()
    }

    private func save() { kv.setValue(reminders, forKey: Self.key) }

    public func contains(sourceId: String, channelId: String, start: Date) -> Bool {
        let id = ProgramReminder.id(sourceId: sourceId, channelId: channelId, start: start)
        return reminders.contains { $0.id == id }
    }

    /// A reminder is possible for programmes that have not started yet.
    public func canRemind(_ program: EpgProgram) -> Bool { program.start > now() }

    /// Adds a reminder (nil when the programme already started). Asks for notification permission on first use.
    @discardableResult
    public func add(channel: Channel, program: EpgProgram) -> ProgramReminder? {
        guard canRemind(program) else { return nil }
        let reminder = ProgramReminder(sourceId: channel.sourceId, channelId: channel.id, channelName: channel.name,
                                       title: program.title, start: program.start, end: program.end)
        guard !reminders.contains(where: { $0.id == reminder.id }) else { return reminder }
        reminders.append(reminder)
        reminders.sort { $0.start < $1.start }
        save()
        if let notifier {
            if !askedPermission {
                askedPermission = true
                Task { @MainActor [weak self] in
                    _ = await notifier.requestAuthorization()
                    self?.schedule(reminder)
                }
            } else {
                schedule(reminder)
            }
        }
        return reminder
    }

    public func remove(id: String) {
        guard reminders.contains(where: { $0.id == id }) else { return }
        reminders.removeAll { $0.id == id }
        save()
        notifier?.cancel(reminderIds: [id])
    }

    public func toggle(channel: Channel, program: EpgProgram) {
        let id = ProgramReminder.id(sourceId: channel.sourceId, channelId: channel.id, start: program.start)
        if reminders.contains(where: { $0.id == id }) { remove(id: id) } else { add(channel: channel, program: program) }
    }

    /// Reminders of a deleted source go too.
    public func removeAll(sourceId: String) {
        let ids = reminders.filter { $0.sourceId == sourceId }.map(\.id)
        guard !ids.isEmpty else { return }
        reminders.removeAll { $0.sourceId == sourceId }
        save()
        notifier?.cancel(reminderIds: ids)
    }

    /// Removes reminders whose programme has ended.
    public func cleanup() {
        let t = now()
        let ended = reminders.filter { $0.end <= t }.map(\.id)
        guard !ended.isEmpty else { return }
        reminders.removeAll { $0.end <= t }
        save()
        notifier?.cancel(reminderIds: ended)
    }

    // MARK: Timing

    /// The moments of one reminder that are still ahead of `after` (start, plus the lead when enabled).
    public func fires(of reminder: ProgramReminder, after: Date) -> [ReminderFire] {
        var out: [ReminderFire] = []
        if remindEarly {
            let early = reminder.start.addingTimeInterval(-Double(Self.leadMinutesOption) * 60)
            if early > after { out.append(ReminderFire(reminder: reminder, date: early, minutesBefore: Self.leadMinutesOption)) }
        }
        if reminder.start > after { out.append(ReminderFire(reminder: reminder, date: reminder.start, minutesBefore: 0)) }
        return out
    }

    /// Next moment the in-app loop has to wake up (nil: nothing ahead).
    public func nextFireDate() -> Date? {
        let t = now()
        return reminders.flatMap { fires(of: $0, after: t.addingTimeInterval(-60)) }
            .filter { !announced.contains($0.key) }.map(\.date).min()
    }

    /// Fires that are due now (within the last `grace` seconds) and not shown yet – marks them shown. A reminder
    /// whose start passed while the app was not running is not announced late (beyond `grace`).
    public func takeDueFires(grace: TimeInterval = 90) -> [ReminderFire] {
        let t = now()
        let due = reminders.flatMap { fires(of: $0, after: t.addingTimeInterval(-grace)) }
            .filter { $0.date <= t && !announced.contains($0.key) }
            .sorted { $0.date < $1.date }
        for fire in due { announced.insert(fire.key) }
        return due
    }

    private func schedule(_ reminder: ProgramReminder) {
        notifier?.schedule(fires(of: reminder, after: now()))
    }

    /// Re-schedules every system notification (lead setting changed, permission granted later).
    public func reschedule() {
        guard let notifier else { return }
        notifier.cancel(reminderIds: reminders.map(\.id))
        let t = now()
        notifier.schedule(reminders.flatMap { fires(of: $0, after: t) })
    }
}
