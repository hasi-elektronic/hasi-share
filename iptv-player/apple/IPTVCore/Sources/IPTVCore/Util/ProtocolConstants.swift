/// Protocol constants shared by every platform (CONTRACT §0). Never change once shipped.
public enum ProtocolConstants {
    /// Prefix hashed into the device key (CONTRACT §7.1).
    public static let deviceKeyPrefix = "iptvp-device-v1"
    /// HKDF `info` for the TV pairing key derivation (CONTRACT §9).
    public static let pairHKDFInfo = "iptvp-pair-v1"
    /// `iss` claim of license tokens (CONTRACT §7.2).
    public static let licenseIssuer = "iptvp-license"
}
