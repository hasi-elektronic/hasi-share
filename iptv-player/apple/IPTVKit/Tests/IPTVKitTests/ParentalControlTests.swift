import XCTest
@testable import IPTVKit
import IPTVCore

/// Parental control (Build 18, SCREENS §3.10): PIN hashing in the Keychain, 5 wrong PINs → 1 min cooldown, session
/// unlock / relock, locks per source, adult-category suggestion, the PIN prompt.
@MainActor
final class ParentalControlTests: XCTestCase {
    var secure = InMemorySecureStore()
    var kv = InMemoryKeyValueStore()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func make() -> ParentalControl {
        ParentalControl(secureStore: secure, kv: kv, now: { [unowned self] in self.clock })
    }

    func testPinIsStoredOnlyAsSaltedHash() throws {
        let parental = make()
        XCTAssertFalse(parental.hasPin)
        XCTAssertTrue(parental.setPin("4711"))
        let stored = try XCTUnwrap(secure.data(forKey: ParentalControl.pinKey))
        XCTAssertNil(String(data: stored, encoding: .utf8).flatMap { $0.range(of: "4711") }, "never the PIN itself")
        let hash = try XCTUnwrap(secure.value(PinHash.self, forKey: ParentalControl.pinKey))
        XCTAssertEqual(hash.salt.count, 16)
        XCTAssertEqual(hash.hash.count, 32)
        XCTAssertTrue(hash.matches("4711"))
        XCTAssertFalse(hash.matches("4712"))
        XCTAssertNotEqual(PinHash.make(pin: "4711").hash, hash.hash, "random salt per PIN")
        XCTAssertEqual(PinHash.make(pin: "4711", salt: hash.salt, iterations: hash.iterations).hash, hash.hash, "deterministic for one salt")
        XCTAssertTrue(make().hasPin, "survives relaunch")
    }

    func testOnlyFourDigitsAreAccepted() {
        let parental = make()
        for bad in ["", "123", "12345", "12a4", "١٢٣٤", " 123"] { XCTAssertFalse(parental.setPin(bad), bad) }
        XCTAssertFalse(parental.hasPin)
    }

    func testFiveWrongPinsStartAOneMinuteCooldown() {
        let parental = make()
        parental.setPin("1234")
        XCTAssertEqual(parental.verify("0000"), .wrong(remaining: 4))
        XCTAssertEqual(parental.verify("0000"), .wrong(remaining: 3))
        XCTAssertEqual(parental.verify("0000"), .wrong(remaining: 2))
        XCTAssertEqual(parental.verify("0000"), .wrong(remaining: 1))
        let until = clock.addingTimeInterval(60)
        XCTAssertEqual(parental.verify("0000"), .coolingDown(until: until))
        XCTAssertEqual(parental.verify("1234"), .coolingDown(until: until), "even the right PIN waits")
        XCTAssertEqual(make().verify("1234"), .coolingDown(until: until), "the cooldown survives relaunch")
        clock = clock.addingTimeInterval(59)
        XCTAssertEqual(parental.verify("1234"), .coolingDown(until: until))
        clock = clock.addingTimeInterval(2)
        XCTAssertNil(parental.cooldownUntil)
        XCTAssertEqual(parental.verify("1234"), .ok)
        XCTAssertEqual(parental.verify("9999"), .wrong(remaining: 4), "a right PIN resets the counter")
    }

    func testUnlockLastsUntilRelock() {
        let parental = make()
        var changes = 0
        parental.onChange = { changes += 1 }
        parental.setPin("1234")
        XCTAssertTrue(parental.isUnlocked, "the parent who set the PIN goes on unlocked")
        parental.relock()
        XCTAssertTrue(parental.isActive)
        XCTAssertNotNil(parental.filter)
        XCTAssertEqual(parental.unlock("1111"), .wrong(remaining: 4))
        XCTAssertTrue(parental.isActive)
        XCTAssertEqual(parental.unlock("1234"), .ok)
        XCTAssertFalse(parental.isActive)
        XCTAssertNil(parental.filter, "nothing is filtered while unlocked")
        XCTAssertEqual(changes, 3, "set, relock, unlock")
        XCTAssertFalse(make().isUnlocked, "a relaunch starts locked")
    }

    func testChangeAndRemovePin() {
        let parental = make()
        parental.setPin("1234")
        XCTAssertEqual(parental.changePin(old: "0000", new: "5678"), .wrong(remaining: 4))
        XCTAssertEqual(parental.changePin(old: "1234", new: "5678"), .ok)
        XCTAssertEqual(parental.verify("5678"), .ok)
        XCTAssertEqual(parental.removePin("1234"), .wrong(remaining: 4))
        XCTAssertTrue(parental.hasPin)
        XCTAssertEqual(parental.removePin("5678"), .ok)
        XCTAssertFalse(parental.hasPin)
        XCTAssertNil(secure.data(forKey: ParentalControl.pinKey))
        XCTAssertEqual(parental.verify("5678"), .noPin)
    }

    func testLocksArePerSourceAndKindAndPersisted() {
        let parental = make()
        parental.setCategoryLocked(true, categoryId: "c9", kind: .live, sourceId: "a")
        parental.setCategoryLocked(true, categoryId: "c9", kind: .movie, sourceId: "b")
        parental.setChannelLocked(true, channelId: "ch1", sourceId: "a")
        XCTAssertTrue(parental.isCategoryLocked("c9", kind: .live, sourceId: "a"))
        XCTAssertFalse(parental.isCategoryLocked("c9", kind: .movie, sourceId: "a"), "Xtream ids collide across kinds")
        XCTAssertFalse(parental.isCategoryLocked("c9", kind: .live, sourceId: "b"))
        let reloaded = make()
        XCTAssertTrue(reloaded.isCategoryLocked("c9", kind: .movie, sourceId: "b"))
        XCTAssertTrue(reloaded.isChannelLocked("ch1", sourceId: "a"))
        XCTAssertNil(reloaded.filter, "no PIN → no filter")
        reloaded.setPin("1234")
        reloaded.relock()
        let filter = try! XCTUnwrap(reloaded.filter)
        XCTAssertEqual(filter.lockedCategories("a", .live), ["c9"])
        XCTAssertEqual(filter.lockedChannels("a"), ["ch1"])
        XCTAssertTrue(filter.hideLocked)
        reloaded.hideLocked = false
        XCTAssertFalse(reloaded.filter!.hideLocked)
        XCTAssertTrue(reloaded.needsPin(categoryId: "c9", kind: .live, sourceId: "a"))
        XCTAssertTrue(reloaded.needsPin(channel: Channel(sourceId: "a", id: "ch1", name: "x")))
        XCTAssertTrue(reloaded.needsPin(channel: Channel(sourceId: "a", id: "ch2", name: "x", categoryId: "c9")))
        XCTAssertFalse(reloaded.needsPin(channel: Channel(sourceId: "a", id: "ch2", name: "x", categoryId: "c1")))
        reloaded.removeAll(sourceId: "a")
        XCTAssertTrue(reloaded.lockedCategoryIds(sourceId: "a", kind: .live).isEmpty)
    }

    func testSettingsProtection() {
        let parental = make()
        XCTAssertFalse(parental.settingsNeedPin, "no PIN")
        parental.setPin("1234")
        parental.relock()
        XCTAssertTrue(parental.settingsNeedPin)
        parental.protectSettings = false
        XCTAssertFalse(parental.settingsNeedPin)
    }

    func testPromptRunsTheActionAfterTheRightPin() {
        let parental = make()
        var ran = 0
        parental.requestUnlock { ran += 1 }
        XCTAssertEqual(ran, 1, "no PIN → at once")
        XCTAssertNil(parental.prompt)
        parental.setPin("1234")
        parental.relock()
        parental.requestUnlock { ran += 1 }
        XCTAssertNotNil(parental.prompt)
        XCTAssertEqual(parental.answerPrompt("0000"), .wrong(remaining: 4))
        XCTAssertNotNil(parental.prompt, "the pad stays for another try")
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(parental.answerPrompt("1234"), .ok)
        XCTAssertNil(parental.prompt)
        XCTAssertEqual(ran, 2)
        parental.relock()
        parental.requestUnlock { ran += 1 }
        parental.cancelPrompt()
        XCTAssertNil(parental.prompt)
        XCTAssertEqual(ran, 2)
    }

    func testAdultCategoryNames() {
        for name in ["XXX", "XXX | Adult", "Adult 18+", "+18 Filme", "18+", "Erotik", "EROTİK", "Yetişkin", "YETİŞKİN KANALLAR",
                     "DE | Erwachsene", "For Adults Only", "Porno HD", "VOD XXX 4K"] {
            XCTAssertTrue(ParentalControl.isAdultCategoryName(name), name)
        }
        for name in ["Kids", "Adultswim", "Sport 1", "Haber", "Erotikthriller-Klassiker", "Documentary", "TR | Ulusal", "1800s"] {
            XCTAssertFalse(ParentalControl.isAdultCategoryName(name), name)
        }
        let parental = make()
        let cats = [IPTVCore.Category(sourceId: "s", id: "1", kind: .live, name: "News", sort: 0),
                    IPTVCore.Category(sourceId: "s", id: "2", kind: .live, name: "XXX", sort: 1),
                    IPTVCore.Category(sourceId: "s", id: "3", kind: .movie, name: "Adult 18+", sort: 0)]
        XCTAssertEqual(parental.adultSuggestions(sourceId: "s", categories: cats).map(\.id), ["2", "3"])
        parental.setCategoryLocked(true, categoryId: "2", kind: .live, sourceId: "s")
        XCTAssertEqual(parental.adultSuggestions(sourceId: "s", categories: cats).map(\.id), ["3"], "already locked ones are not offered")
        XCTAssertFalse(parental.wasSuggestionOffered(sourceId: "s"))
        parental.markSuggestionOffered(sourceId: "s")
        XCTAssertTrue(make().wasSuggestionOffered(sourceId: "s"))
    }
}
