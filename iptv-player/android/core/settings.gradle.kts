// Standalone pure Kotlin/JVM build. Resolves ONLY from Maven Central / Gradle Plugin Portal
// so it builds and tests without Google Maven:  gradle -p iptv-player/android/core test
// It is also an included build of the Android root project (../settings.gradle.kts).

pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
    versionCatalogs {
        create("libs") {
            from(files("../gradle/libs.versions.toml"))
        }
    }
}

rootProject.name = "core"
