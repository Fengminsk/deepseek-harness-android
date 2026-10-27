import java.security.MessageDigest
import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The candidate PRoot and Alpine images have not passed the distribution gate.
// Reject accidental source-set inclusion before Android packaging starts. The
// final APK verifier separately checks the assembled artifact.
val unreviewedLinuxGuestInputs = fileTree("src") {
    include("**/libdsh_proot_candidate.so")
    include("**/libdsh_proot_loader_candidate.so")
    include("**/libpocket_linux_guest_supervisor.so")
    include("**/alpine-minirootfs*")
    include("**/rootfs.tar*")
    include("**/linux-vm/**")
    include("**/libpocket_linux_vm.so")
}
if (!unreviewedLinuxGuestInputs.isEmpty) {
    throw GradleException("Linux guest payload is not approved for APK packaging")
}
val pinnedCandidateDigestByLength = mapOf(
    1334216L to "c22cdb13c5de4b6e0022f7ede7a5ca0bf88675d4b674aa339a885b96d8b26f7f",
    9952L to "c5e85afb7599bd82f2419fb054d597514d5c9578954288bef0c5320cd8b63fbf",
)
for (input in fileTree("src").files) {
    val expected = pinnedCandidateDigestByLength[input.length()] ?: continue
    val digest = MessageDigest.getInstance("SHA-256")
    input.inputStream().buffered().use { stream ->
        val buffer = ByteArray(65536)
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    val actual = digest.digest().joinToString("") { "%02x".format(it) }
    if (actual == expected) {
        throw GradleException("Pinned Linux guest ELF is not approved for APK packaging: ${input.name}")
    }
}

val acceptanceBuildType = providers.gradleProperty("dshAcceptanceBuildType").orElse("debug").get()
val linuxGuestFixture = providers.gradleProperty("dshLinuxGuestFixture").orElse("false").get() == "true"
val linuxCandidatePath = providers.gradleProperty("dshLinuxCandidate").orNull
val linuxVmEnabled = linuxGuestFixture || linuxCandidatePath != null
require(acceptanceBuildType in setOf("debug", "release")) {
    "dshAcceptanceBuildType must be debug or release"
}
require(!linuxGuestFixture || linuxCandidatePath == null) {
    "Select either dshLinuxCandidate or dshLinuxGuestFixture, never both"
}
// Candidate selection supplies the native carrier for acceptance only. The
// separate model registration/device gates are not changed by this property.
val candidateAssets = linuxCandidatePath?.let { selected ->
    require(acceptanceBuildType == "release") { "Alpine candidates require dshAcceptanceBuildType=release" }
    val repository = rootProject.file("../../..").canonicalFile
    val directory = file(selected)
    val candidateRoot = repository.resolve(".cache/android/linux-vm-candidates").canonicalFile
    require(File(selected).isAbsolute && directory.canonicalFile.parentFile == candidateRoot &&
        directory.name.startsWith("alpine-") && directory.resolve("candidate.json").isFile) {
        "dshLinuxCandidate must name an absolute staged Alpine directory in this repository cache"
    }
    val digest = MessageDigest.getInstance("SHA-256")
        .digest(directory.resolve("candidate.json").readBytes()).joinToString("") { "%02x".format(it) }
    val assets = repository.resolve(".cache/android/linux-vm-release-assets/${directory.name}/$digest/assets")
    val python = providers.gradleProperty("dshLinuxPython").orElse("python").get()
    val verifier = repository.resolve("apps/android/tool/linux-vm-release.py").absolutePath
    val selection = listOf("--candidate", directory.absolutePath, "--candidate-sha256", digest)
    val prepare = tasks.register<Exec>("prepareLinuxCandidateAssets") {
        workingDir(repository)
        commandLine(listOf(python, verifier, "prepare") + selection)
        // Source closure and every cached input must be rechecked on each build.
        outputs.upToDateWhen { false }
    }
    tasks.named("preBuild").configure { dependsOn(prepare) }
    val audit = tasks.register<Exec>("verifyLinuxCandidateApk") {
        dependsOn("packageRelease", "stripReleaseDebugSymbols")
        workingDir(repository)
        commandLine(listOf(python, verifier, "verify-apk") + selection + listOf(
            "--apk", layout.buildDirectory.file("outputs/apk/release/app-release.apk").get().asFile.absolutePath,
            "--native-library", layout.buildDirectory.file(
                "intermediates/stripped_native_libs/release/stripReleaseDebugSymbols/out/lib/arm64-v8a/libpocket_linux_vm.so"
            ).get().asFile.absolutePath,
            "--report", layout.buildDirectory.file("reports/linux-vm-release.json").get().asFile.absolutePath,
        ))
        outputs.upToDateWhen { false }
    }
    tasks.matching { it.name == "assembleRelease" }.configureEach { dependsOn(audit) }
    gradle.taskGraph.whenReady {
        require(allTasks.none { it.project == project && it.name.contains("Debug") &&
            !it.name.contains("Release") }) {
            "Alpine candidates support release builds only"
        }
    }
    assets
}

android {
    sourceSets.getByName("androidTest").assets.srcDir(rootProject.file("../tool/device-runtime-acceptance"))
    if (candidateAssets != null) {
        sourceSets.getByName("release").assets.srcDir(candidateAssets)
    }
    if (linuxGuestFixture) {
        require(acceptanceBuildType == "release") { "Linux boot fixtures require the explicit acceptance release variant" }
        val fixtureAssets = rootProject.file("../../../.cache/android/linux-vm-assets")
        require(fixtureAssets.resolve("linux-vm/manifest.json").isFile) {
            "Run node apps/android/tool/stage-linux-vm-fixture.mjs before Linux device acceptance"
        }
        sourceSets.getByName("main").assets.srcDir(fixtureAssets)
        sourceSets.getByName("androidTest").assets.srcDir(rootProject.file("../../../.cache/android/linux-image-build-assets"))
    }
    // Instrumentation must use the same variant and R8 mapping as the installed App.
    testBuildType = acceptanceBuildType
    namespace = "com.minnnng.dsh_android"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    buildFeatures { buildConfig = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.minnnng.dsh_android"
        testInstrumentationRunner = "com.minnnng.dsh_android.IsolatedScriptAcceptanceInstrumentation"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = 36
        buildConfigField("boolean", "LINUX_VM_ENABLED", linuxVmEnabled.toString())
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild { cmake {
            cppFlags += "-std=c++20"
            arguments += "-DANDROID_STL=c++_shared"
            // Cache values from a manual NDK experiment must never leak into App builds.
            arguments += "-DDSH_BUILD_LINUX_GUEST_SUPERVISOR=OFF"
            arguments += "-DDSH_BUILD_LINUX_VM=${if (linuxVmEnabled) "ON" else "OFF"}"
        } }
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    packaging { jniLibs {
        useLegacyPackaging = true
        // This PIE executable is verified byte-for-byte against the runtime lock.
        keepDebugSymbols += "**/libpocket_ripgrep.so"
    } }

    buildTypes {
        release {
            proguardFile("linux-vm-rules.pro")
            if (acceptanceBuildType == "release") {
                // Preserve only APIs directly exercised by the separately compiled probe.
                // Ordinary release builds keep their normal R8 shrinking configuration.
                proguardFile("proguard-acceptance.pro")
            }
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.browser:browser:1.10.0")
    implementation("androidx.webkit:webkit:1.15.0")
}
