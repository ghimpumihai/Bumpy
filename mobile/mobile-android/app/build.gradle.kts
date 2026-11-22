plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

/** The commit the app was built from, as in the iOS app's `GitCommit` (shown in `appVersion`). */
val gitCommit: String = providers.exec {
    commandLine("git", "rev-parse", "--short", "HEAD")
    isIgnoreExitValue = true
}.standardOutput.asText.map { it.trim().ifEmpty { "unknown" } }.getOrElse("unknown")

android {
    namespace = "com.chuds.sensorrecorder"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.chuds.sensorrecorder"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
        buildConfigField("String", "GIT_COMMIT", "\"$gitCommit\"")
        // Address of the web dashboard; its links are hidden while this is empty (./gradlew -PdashboardUrl=https://…).
        buildConfigField("String", "DASHBOARD_URL", "\"${providers.gradleProperty("dashboardUrl").getOrElse("")}\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Sideloaded onto the team's phones, like the iOS app's free provisioning; not a store build.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests.all {
            val fixtures = rootProject.file("../mobile-ios/tools/fixtures")
            // Where the tests write the samples that tools/check_contract.py runs through the ingest validator.
            val contract = layout.buildDirectory.dir("contract")
            it.systemProperty("ios.fixtures", fixtures.path)
            it.systemProperty("contract.out", contract.get().asFile.path)
            // Declared, or a changed fixture leaves the tests "up to date" and they are skipped.
            it.inputs.dir(fixtures)
            it.outputs.dir(contract)
            it.maxHeapSize = "1g"
        }
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
}
