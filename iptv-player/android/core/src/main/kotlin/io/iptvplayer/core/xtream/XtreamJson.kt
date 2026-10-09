package io.iptvplayer.core.xtream

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.math.BigDecimal

/**
 * Lenient accessors for Xtream panel JSON (CONTRACT §4.3). Panels are inconsistent:
 * numbers arrive as JSON numbers, numeric strings, `""` or `null`; booleans as `1`, `"1"`,
 * `true`; empty objects as `[]`. Every accessor returns null instead of throwing.
 */
public object XtreamJson {
    /**
     * Strict JSON (no lenient mode): an HTML error page must fail to parse instead of being
     * read as an unquoted string literal.
     */
    public val parser: Json = Json { ignoreUnknownKeys = true }

    /**
     * Parses [text]; null when it is not JSON. kotlinx accepts a bare unquoted top-level token
     * (e.g. `<html>…`) as a literal even in strict mode, so such results are rejected here.
     */
    public fun parseOrNull(text: String): JsonElement? {
        val e = try {
            parser.parseToJsonElement(text)
        } catch (_: Exception) {
            return null
        }
        if (e is JsonPrimitive && e !is JsonNull && !e.isString) {
            val c = e.content
            if (c != "true" && c != "false" && c.toDoubleOrNull() == null) return null
        }
        return e
    }

    /**
     * Non-empty string value: strings as-is (empty → null), numbers in canonical form
     * (`1001`, `1001.0` → `"1001"`), booleans as `true`/`false`; objects/arrays → null.
     */
    public fun string(e: JsonElement?): String? {
        if (e !is JsonPrimitive || e is JsonNull) return null
        if (e.isString) return e.content.takeIf { it.isNotEmpty() }
        val c = e.content
        if (c == "true" || c == "false") return c
        return canonicalNumber(c) ?: c.takeIf { it.isNotEmpty() }
    }

    /** Like [string] but trimmed; blank → null (ids, URLs). */
    public fun trimmed(e: JsonElement?): String? = string(e)?.trim()?.takeIf { it.isNotEmpty() }

    /** Integer: JSON number or numeric string (`"7"`, `"7.0"`); fractional → truncated; else null. */
    public fun long(e: JsonElement?): Long? {
        val s = numericText(e) ?: return null
        s.toLongOrNull()?.let { return it }
        return try {
            BigDecimal(s).toLong()
        } catch (_: NumberFormatException) {
            null
        }
    }

    /** [long] narrowed to Int (null when out of range). */
    public fun int(e: JsonElement?): Int? = long(e)?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()

    /** Double: JSON number or numeric string; `""`/null/NaN → null. */
    public fun double(e: JsonElement?): Double? = numericText(e)?.toDoubleOrNull()?.takeIf { it.isFinite() }

    /** Boolean: `1`, `"1"`, `true`, `"true"` → true; anything else false. */
    public fun bool(e: JsonElement?): Boolean {
        if (e !is JsonPrimitive || e is JsonNull) return false
        val c = e.content.trim()
        return c == "1" || c.equals("true", ignoreCase = true) || (long(e) == 1L)
    }

    /** Object value; an empty array `[]` counts as an empty object; anything else → null. */
    public fun obj(e: JsonElement?): JsonObject? = when (e) {
        is JsonObject -> e
        is JsonArray -> if (e.isEmpty()) EMPTY else null
        else -> null
    }

    /** Array value or null. */
    public fun array(e: JsonElement?): JsonArray? = e as? JsonArray

    /**
     * Items of a list response: an array, or the values of an object ordered by numeric key
     * (some panels return `{"0": {...}, "1": {...}}`). Anything else → empty.
     */
    public fun listItems(e: JsonElement?): List<JsonElement> = when (e) {
        is JsonArray -> e
        is JsonObject -> sortedEntries(e).map { it.second }
        else -> emptyList()
    }

    /** Object entries sorted by numeric key first (ascending), then lexicographically. */
    public fun sortedEntries(o: JsonObject): List<Pair<String, JsonElement>> =
        o.entries.map { it.key to it.value }.sortedWith(
            Comparator { a, b ->
                val x = a.first.trim().toLongOrNull()
                val y = b.first.trim().toLongOrNull()
                when {
                    x != null && y != null -> x.compareTo(y)
                    x != null -> -1
                    y != null -> 1
                    else -> a.first.compareTo(b.first)
                }
            },
        )

    /** Member [key] of [e] when it is an object (`[]` → no members). */
    public operator fun JsonElement?.get(key: String): JsonElement? = obj(this)?.get(key)

    private val EMPTY = JsonObject(emptyMap())

    private fun numericText(e: JsonElement?): String? {
        if (e !is JsonPrimitive || e is JsonNull) return null
        val c = e.content.trim()
        if (c.isEmpty()) return null
        if (!e.isString) return c.takeIf { it != "true" && it != "false" }
        return c.takeIf { NUMERIC.matches(it) }
    }

    private val NUMERIC = Regex("""[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?""")

    private fun canonicalNumber(c: String): String? {
        c.toLongOrNull()?.let { return it.toString() }
        return try {
            val bd = BigDecimal(c)
            if (bd.signum() == 0 || bd.stripTrailingZeros().scale() <= 0) bd.toBigInteger().toString() else bd.toPlainString()
        } catch (_: NumberFormatException) {
            null
        }
    }
}
