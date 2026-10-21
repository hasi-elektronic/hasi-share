package io.iptvplayer.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.fail

/** Access to the shared cross-platform vectors (`spec/test-vectors`). */
object Vectors {
    val dir: File by lazy {
        val p = System.getProperty("vectors.dir") ?: error("system property vectors.dir not set")
        File(p).also { require(it.isDirectory) { "vectors dir not found: $it" } }
    }

    fun file(path: String): File = File(dir, path).also { require(it.isFile) { "missing vector $it" } }

    fun text(path: String): String = file(path).readText(Charsets.UTF_8)

    fun json(path: String): JsonElement = Json.parseToJsonElement(text(path))
}

/** JSON with explicit nulls, matching the `*.expected.json` conventions. */
val TestJson = Json {
    explicitNulls = true
    encodeDefaults = true
}

/**
 * Structural JSON comparison: numbers are compared numerically (7200 == 7200.0), keys must match
 * exactly (keys starting with `_` in [expected] are documentation and ignored).
 */
fun assertJsonEquals(expected: JsonElement, actual: JsonElement, path: String = "$") {
    when (expected) {
        is JsonNull -> if (actual !is JsonNull) fail("$path: expected null, got $actual")
        is JsonPrimitive -> {
            if (actual !is JsonPrimitive || actual is JsonNull) fail("$path: expected $expected, got $actual")
            when {
                expected.isString -> {
                    if (!actual.isString) fail("$path: expected string $expected, got $actual")
                    assertEquals(expected.content, actual.content, "$path")
                }
                expected.booleanOrNull != null -> assertEquals(expected.booleanOrNull, actual.booleanOrNull, path)
                else -> {
                    val e = expected.doubleOrNull ?: fail("$path: not a number $expected")
                    val a = actual.doubleOrNull ?: fail("$path: expected number $expected, got $actual")
                    assertEquals(e, a, 1e-9, path)
                }
            }
        }
        is JsonArray -> {
            if (actual !is JsonArray) fail("$path: expected array, got $actual")
            assertEquals(expected.size, actual.size, "$path: array size (actual=$actual)")
            expected.forEachIndexed { i, e -> assertJsonEquals(e, actual[i], "$path[$i]") }
        }
        is JsonObject -> {
            if (actual !is JsonObject) fail("$path: expected object, got $actual")
            val eKeys = expected.keys.filterNot { it.startsWith("_") }.toSet()
            assertEquals(eKeys, actual.keys.filterNot { it.startsWith("_") }.toSet(), "$path: keys")
            for (k in eKeys) assertJsonEquals(expected.getValue(k), actual.getValue(k), "$path.$k")
        }
    }
}
