import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    `java-library`
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

// Coordinates used by the Android modules (`implementation("io.iptvplayer:core")`);
// the root build substitutes them with this included build.
group = "io.iptvplayer"
version = "1.0.0"

java {
    // Bytecode/API level 17 (Android-compatible). The container only ships JDK 21 and
    // toolchain auto-provisioning (foojay) is not reachable, so instead of
    // `jvmToolchain(17)` we compile with the current JDK and pin release 17.
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    explicitApi()
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        freeCompilerArgs.addAll(
            "-Xjdk-release=17",
            "-opt-in=kotlinx.serialization.ExperimentalSerializationApi",
        )
    }
}

dependencies {
    api(libs.kotlinx.coroutines.core)
    api(libs.kotlinx.serialization.json)
    api(libs.okhttp)
    api(libs.okio)
    // XmlPullParser API: provided by the Android framework at runtime (Xml.newPullParser()).
    // Never bundled into the APK.
    compileOnly(libs.kxml2)

    testImplementation(libs.kxml2)
    testImplementation(libs.kotlin.test.junit5)
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
    testRuntimeOnly(libs.junit.platform.launcher)
}

tasks.test {
    useJUnitPlatform()
    // Shared cross-platform vectors live in iptv-player/spec/test-vectors.
    systemProperty("vectors.dir", rootDir.resolve("../../spec/test-vectors").canonicalPath)
    // Small heap on purpose: the large-playlist test proves the M3U parser streams
    // (a fully materialized 200k-entry playlist would not fit).
    maxHeapSize = "512m"
    testLogging {
        events("failed", "skipped")
        showStandardStreams = false
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
    inputs.dir(rootDir.resolve("../../spec/test-vectors"))
}
