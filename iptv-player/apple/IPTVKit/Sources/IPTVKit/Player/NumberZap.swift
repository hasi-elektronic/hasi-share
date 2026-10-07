import Foundation
import IPTVCore

/// TV number zapping (SCREENS §3.7): digits typed within `timeoutMs` of each other form one channel
/// number (max 4 digits); the number is tuned once no further digit arrives for `timeoutMs`.
public struct NumberZap: Sendable {
    private let timeoutMs: Int64
    private var buffer = ""
    private var lastMs: Int64 = 0

    public init(timeoutMs: Int = 1500) { self.timeoutMs = Int64(timeoutMs) }

    /// Digits entered so far (empty when nothing is pending).
    public var pending: String { buffer }

    /// Feed a digit at time `ms`; returns the buffer to display.
    public mutating func input(_ digit: Int, atMs ms: Int64) -> String {
        if buffer.count < 4 { buffer.append(String(digit)) }
        lastMs = ms
        return buffer
    }

    /// Returns the number to tune to if the timeout elapsed since the last digit (and clears), else nil.
    public mutating func commitIfDue(atMs ms: Int64) -> Int? {
        guard !buffer.isEmpty, ms - lastMs >= timeoutMs else { return nil }
        defer { buffer = "" }
        return Int(buffer)
    }

    /// The channel to tune for a typed number: the one whose `number` matches, else the n-th of
    /// the list (1-based) – playlists without channel numbers.
    public static func channel(number: Int, in channels: [Channel]) -> Channel? {
        if let match = channels.first(where: { $0.number == number }) { return match }
        return channels.indices.contains(number - 1) ? channels[number - 1] : nil
    }
}
