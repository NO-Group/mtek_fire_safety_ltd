allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Some plugins (e.g. file_picker's bundled androidx.core/lifecycle deps)
// ship compiled against an older Android SDK than this app's own compileSdk,
// which fails Gradle's AAR-metadata check ("X is currently compiled against
// android-34"). Force every Android subproject (i.e. plugin modules) to
// compile against the same SDK as the app module. Uses reflection (instead
// of importing AGP's LibraryExtension/BaseExtension types) so this script
// does not need AGP on its own compile classpath -- compile-time only,
// does not touch any plugin's own minSdk/targetSdk or runtime behavior.
subprojects {
    afterEvaluate {
        val androidExt = project.extensions.findByName("android") ?: return@afterEvaluate
        val cls = androidExt.javaClass
        // AGP's setter signature has changed across versions (setCompileSdk(Integer)
        // in newer AGP, compileSdkVersion(int) as the older/deprecated form) --
        // try each in turn so this keeps working regardless of AGP version.
        val attempts: List<() -> Unit> = listOf(
            { cls.getMethod("setCompileSdk", Integer::class.java).invoke(androidExt, 36) },
            { cls.getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType).invoke(androidExt, 36) },
            { cls.getMethod("compileSdkVersion", Int::class.javaPrimitiveType).invoke(androidExt, 36) },
        )
        for (attempt in attempts) {
            try {
                attempt()
                break
            } catch (_: NoSuchMethodException) {
                // Try the next known setter signature.
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
