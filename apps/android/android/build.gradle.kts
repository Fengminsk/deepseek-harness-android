allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Flutter resolves declared snapshot paths but retains asset depfile paths.
// Both must use the same physical directory when build/ is a Windows junction.
val requestedBuildDir = rootProject.layout.buildDirectory.dir("../../build").get().asFile
requestedBuildDir.mkdirs()
val physicalBuildDir = requestedBuildDir.toPath().toRealPath().toFile()
rootProject.layout.buildDirectory.fileValue(physicalBuildDir)

subprojects {
    val newSubprojectBuildDir = rootProject.layout.buildDirectory.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
