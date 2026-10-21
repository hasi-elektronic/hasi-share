import Foundation
import IPTVCore
import Observation

/// Paywall / trial card (docs/SCREENS.md §3.1, §3.8).
@MainActor
@Observable
public final class PaywallViewModel {
    /// Message shown after an action (localization key + argument).
    public struct Message: Equatable, Sendable {
        public var key: String
        public var arg: String?
        public var isError: Bool
    }

    public private(set) var message: Message?
    public private(set) var busy = false
    @ObservationIgnored private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var decision: AccessDecision { env.license.decision }
    public var price: String? { env.store.lifetimePrice }
    public var trialDays: Int { env.license.trialDays }
    public var storeState: StoreState { env.store.snapshot.lifetime }

    public func buy() async {
        busy = true
        defer { busy = false }
        message = Self.message(for: await env.store.purchaseLifetime())
        env.license.evaluate()
    }

    public func startTrial() async {
        busy = true
        defer { busy = false }
        let outcome = await env.store.startTrial()
        if outcome != .success { message = Self.message(for: outcome) } else { message = nil }
        await env.license.sync()
    }

    public func restore() async {
        busy = true
        defer { busy = false }
        let outcome = await env.store.restore()
        message = outcome == .success ? Message(key: "purchase_restored", arg: nil, isError: false) : Self.message(for: outcome)
        await env.license.sync()
    }

    static func message(for outcome: PurchaseOutcome) -> Message? {
        switch outcome {
        case .success: return Message(key: "purchase_owned", arg: nil, isError: false)
        case .pending: return Message(key: "purchase_pending", arg: nil, isError: false)
        case .cancelled: return nil
        case .alreadyOwned: return Message(key: "purchase_owned", arg: nil, isError: false)
        case .nothingToRestore: return Message(key: "purchase_nothing_to_restore", arg: nil, isError: true)
        case .failed(let text): return Message(key: "purchase_failed", arg: text, isError: true)
        case .unavailable: return Message(key: "purchase_unavailable", arg: nil, isError: true)
        }
    }
}
