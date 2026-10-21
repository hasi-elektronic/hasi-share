package io.iptvplayer.core

import kotlinx.serialization.json.Json

/**
 * Protocol constants shared by Android, Apple and the backend (CONTRACT §0).
 * They are part of the wire protocol and must never change once shipped.
 */
public object CoreConstants {
    /** Prefix of the device key hash input (CONTRACT §7.1). */
    public const val DEVICE_KEY_PREFIX: String = "iptvp-device-v1"

    /** HKDF `info` used to derive the pairing AES key (CONTRACT §9). */
    public const val PAIR_HKDF_INFO: String = "iptvp-pair-v1"

    /** `iss` claim of license tokens (CONTRACT §7.2). */
    public const val LICENSE_ISSUER: String = "iptvp-license"

    /** Default trial length when no server config is cached yet (CONTRACT §7.4). */
    public const val DEFAULT_TRIAL_DAYS: Int = 7
}

/**
 * The JSON configuration used everywhere in core: unknown keys are ignored (servers evolve),
 * defaults are encoded, nulls of optional fields are omitted.
 */
public val CoreJson: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = false
    coerceInputValues = true
    isLenient = true
}
