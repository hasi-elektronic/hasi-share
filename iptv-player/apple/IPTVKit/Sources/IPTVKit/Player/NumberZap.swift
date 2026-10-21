import Foundation

/// TV number zapping (SCREENS §3.7): digits typed within `timeoutMs` of each other form one channel
/// number (max 4 digits); the number is tuned once no further digit arrives for `timeoutMs`
/// (target: `CatalogRepository.channelForNumberZap`).
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
}
