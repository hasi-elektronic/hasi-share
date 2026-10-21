import XCTest
@testable import IPTVKit
import IPTVCore

/// Programme reminders (Build 18, SCREENS §3.4): scheduling at the start (+ optional 5 min before), persistence,
/// cleanup after the programme, the in-app banner's due fires.
@MainActor
final class ReminderStoreTests: XCTestCase {
    final class Notifier: ReminderNotifier {
        var authorizationRequests = 0
        var scheduled: [ReminderFire] = []
        var cancelled: [String] = []
        func requestAuthorization() async -> Bool { authorizationRequests += 1; return true }
        func schedule(_ fires: [ReminderFire]) { scheduled += fires }
        func cancel(reminderIds: [String]) { cancelled += reminderIds }
    }

    var kv = InMemoryKeyValueStore()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let channel = Channel(sourceId: "s", id: "7", name: "Atlas News HD")

    private func make() -> ReminderStore { ReminderStore(kv: kv, now: { [unowned self] in self.clock }) }

    private func program(in minutes: Double, length: Double = 60, title: String = "Derby Day") -> EpgProgram {
        let start = clock.addingTimeInterval(minutes * 60)
        return EpgProgram(sourceId: "s", channelEpgId: "e7", start: start, end: start.addingTimeInterval(length * 60), title: title)
    }

    func testOnlyFutureProgrammesAndNoDuplicates() {
        let store = make()
        XCTAssertNil(store.add(channel: channel, program: program(in: -10)), "already started")
        let p = program(in: 30)
        XCTAssertNotNil(store.add(channel: channel, program: p))
        store.add(channel: channel, program: p)
        XCTAssertEqual(store.reminders.count, 1)
        XCTAssertTrue(store.contains(sourceId: "s", channelId: "7", start: p.start))
        store.toggle(channel: channel, program: p)
        XCTAssertTrue(store.reminders.isEmpty, "toggle removes")
    }

    func testRemindersSurviveRelaunchSortedByStart() {
        let store = make()
        store.add(channel: channel, program: program(in: 120, title: "Late"))
        store.add(channel: channel, program: program(in: 30, title: "Soon"))
        let reloaded = make()
        XCTAssertEqual(reloaded.reminders.map(\.title), ["Soon", "Late"])
        XCTAssertEqual(reloaded.reminders.first?.channelName, "Atlas News HD")
    }

    func testEndedProgrammesAreCleanedUp() {
        let notifier = Notifier()
        let store = make()
        store.notifier = notifier
        store.add(channel: channel, program: program(in: 10, length: 30, title: "A"))
        store.add(channel: channel, program: program(in: 120, title: "B"))
        clock = clock.addingTimeInterval(41 * 60)   // A ended
        store.cleanup()
        XCTAssertEqual(store.reminders.map(\.title), ["B"])
        XCTAssertEqual(notifier.cancelled.count, 1)
        clock = clock.addingTimeInterval(10 * 3600)
        XCTAssertTrue(make().reminders.isEmpty, "a relaunch after the programme cleans up too")
    }

    func testNotificationsAtStartAndOptionallyFiveMinutesBefore() async {
        let notifier = Notifier()
        let store = make()
        store.notifier = notifier
        let p = program(in: 30)
        store.add(channel: channel, program: p)
        for _ in 0..<20 where notifier.scheduled.isEmpty { await Task.yield() }
        XCTAssertEqual(notifier.authorizationRequests, 1, "permission asked on first use")
        XCTAssertEqual(notifier.scheduled.map(\.date), [p.start])
        XCTAssertEqual(notifier.scheduled.first?.minutesBefore, 0)
        notifier.scheduled = []
        store.remindEarly = true
        XCTAssertEqual(notifier.scheduled.map(\.date), [p.start.addingTimeInterval(-300), p.start], "rescheduled with the lead")
        XCTAssertEqual(notifier.scheduled.first?.minutesBefore, 5)
        XCTAssertTrue(make().remindEarly, "setting persisted")
        // A programme starting in 3 minutes has no "5 min before" left.
        XCTAssertEqual(store.fires(of: ProgramReminder(sourceId: "s", channelId: "7", channelName: "", title: "", start: clock.addingTimeInterval(180),
                                                       end: clock.addingTimeInterval(3600)), after: clock).map(\.minutesBefore), [0])
        store.remove(id: store.reminders[0].id)
        XCTAssertEqual(notifier.cancelled.last, ProgramReminder.id(sourceId: "s", channelId: "7", start: p.start))
    }

    func testInAppBannerFiresOnceAtTheStart() {
        let store = make()
        let p = program(in: 30)
        store.add(channel: channel, program: p)
        XCTAssertEqual(store.nextFireDate(), p.start)
        XCTAssertTrue(store.takeDueFires().isEmpty)
        clock = p.start.addingTimeInterval(5)
        let due = store.takeDueFires()
        XCTAssertEqual(due.map(\.reminder.title), ["Derby Day"])
        XCTAssertTrue(store.takeDueFires().isEmpty, "shown once")
        XCTAssertNil(store.nextFireDate())
    }

    func testMissedStartIsNotAnnouncedLate() {
        let store = make()
        let p = program(in: 30)
        store.add(channel: channel, program: p)
        clock = p.start.addingTimeInterval(10 * 60)   // app was not running at the start
        XCTAssertTrue(make().takeDueFires().isEmpty)
    }

    func testAutoSwitchSettingPersists() {
        let store = make()
        XCTAssertFalse(store.autoSwitch)
        store.autoSwitch = true
        XCTAssertTrue(make().autoSwitch)
    }

    func testRemoveAllOfASource() {
        let store = make()
        store.add(channel: channel, program: program(in: 30))
        store.add(channel: Channel(sourceId: "other", id: "1", name: "X"), program: program(in: 40))
        store.removeAll(sourceId: "s")
        XCTAssertEqual(store.reminders.map(\.sourceId), ["other"])
    }
}
