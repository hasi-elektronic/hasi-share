// Root build of the Android family (phone + TV share one APK / applicationId).
//
// `core` is a standalone pure Kotlin/JVM build (included build) so it can be built and tested
// without the Android Gradle Plugin:  gradle -p core test
// Android modules depend on it via the coordinates `io.iptvplayer:core`, which Gradle
// substitutes with the included build automatically.

pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "iptv-player-android"

includeBuild("core")
include(":shared", ":app")
