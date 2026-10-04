import java.util.Properties
import com.android.build.api.variant.ApplicationAndroidComponentsExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// ---------------------------------------------------------------------------------------------
// Product placeholders come ONLY from gradle.properties (CONTRACT §0). Debug builds may point at a
// local backend: -PDEBUG_BACKEND_BASE_URL=http://10.0.2.2:8798 (or set it in ~/.gradle/gradle.properties).
// ---------------------------------------------------------------------------------------------
fun prop(name: String, default: String? = null): String =
    (findProperty(name) as String?)?.takeIf { it.isNotBlank() } ?: default ?: error("gradle property $name missing")

val appName = prop("APP_NAME")
val appId = prop("APP_ID")
val productLifetime = prop("PRODUCT_LIFETIME")
val backendBaseUrl = prop("BACKEND_BASE_URL")
val debugBackendBaseUrl = prop("DEBUG_BACKEND_BASE_URL", backendBaseUrl)
fun String.quoted() = "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""

android {
    namespace = "io.iptvplayer.app"
    compileSdk = 36

    defaultConfig {
        applicationId = appId
        minSdk = 23
        targetSdk = 36
        versionCode = prop("VERSION_CODE", "1").toInt()
        versionName = prop("VERSION_NAME", "1.0.0")
        resValue("string", "app_name", appName)
        buildConfigField("String", "APP_ID", appId.quoted())
        buildConfigField("String", "APP_NAME", appName.quoted())
        buildConfigField("String", "PRODUCT_LIFETIME", productLifetime.quoted())
        buildConfigField("String", "BACKEND_BASE_URL", backendBaseUrl.quoted())
    }

    signingConfigs {
        // Release signing: keystore.properties (not in git) – see README. Falls back to unsigned.
        val ksFile = rootProject.file("keystore.properties")
        if (ksFile.exists()) {
            val p = Properties().apply { ksFile.inputStream().use { load(it) } }
            create("release") {
                storeFile = rootProject.file(p.getProperty("storeFile"))
                storePassword = p.getProperty("storePassword")
                keyAlias = p.getProperty("keyAlias")
                keyPassword = p.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            buildConfigField("String", "BACKEND_BASE_URL", debugBackendBaseUrl.quoted())
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfigs.findByName("release")?.let { signingConfig = it }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "/META-INF/versions/9/previous-compilation-data.bin")
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
        checkDependencies = true
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion", "MissingTranslation")
        // spec/strings.json is shared with the Apple apps: not every key is used on Android.
        disable += "UnusedResources"
    }

    // In-app language switch (SCREENS §3.9) needs all language resources in every install.
    bundle {
        language { enableSplit = false }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        freeCompilerArgs.addAll("-opt-in=androidx.tv.material3.ExperimentalTvMaterial3Api")
    }
}

// spec/test-vectors/stream-samples.json is bundled as an asset for the in-app format test
// (single source – never copied by hand).
abstract class CopyStreamSamples : DefaultTask() {
    @get:InputFile
    abstract val samples: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val out = outputDir.get().asFile
        out.mkdirs()
        samples.get().asFile.copyTo(out.resolve("stream-samples.json"), overwrite = true)
    }
}

val copyStreamSamples = tasks.register<CopyStreamSamples>("copyStreamSamples") {
    samples.set(rootProject.layout.projectDirectory.file("../spec/test-vectors/stream-samples.json"))
    outputDir.set(layout.buildDirectory.dir("generated/streamSamples"))
}

extensions.getByType<ApplicationAndroidComponentsExtension>().onVariants { variant ->
    variant.sources.assets?.addGeneratedSourceDirectory(copyStreamSamples, CopyStreamSamples::outputDir)
}

dependencies {
    implementation(project(":shared"))

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)
    implementation(libs.androidx.tv.material)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.paging.compose)
    implementation(libs.androidx.media3.ui)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)

    testImplementation(libs.junit4)
    testImplementation(libs.kotlin.test)
}
