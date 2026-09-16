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

// Plugin modules that never set a Kotlin jvmTarget inherit the JDK that runs
// Gradle (25, from Android Studio's bundled JBR) while their Java sources stay
// on 17 or lower, and Kotlin fails the build on the mismatch: a plugin's build
// script sets jvmTarget only on AGP < 9, and expects Built-in Kotlin to derive
// it from compileOptions otherwise, which never happens because we set
// android.builtInKotlin=false. Pin both compilers on every module instead of
// chasing each plugin.
// Java has to be raised through AGP rather than the JavaCompile tasks: AGP
// derives those from compileOptions and overwrites a task-level value
// (flutter_webrtc stayed on 1.8 and failed the same check in reverse).
// finalizeDsl runs after the plugin's own android {} block, so it wins.
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension> {
            finalizeDsl { android ->
                android.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
                android.compileOptions.targetCompatibility = JavaVersion.VERSION_17
            }
            // Plugin modules live in the pub cache (C:) while their build
            // output lives under this project (F:). Registering a unit-test
            // variant makes AGP relativize one path against the other, which
            // Windows cannot do across drives, and Gradle sync fails with
            // "this and base files have different roots". Nobody runs a
            // plugin's own unit tests from here, so they are not registered.
            beforeVariants { variant ->
                variant.hostTests[com.android.build.api.variant.HostTestBuilder.UNIT_TEST_TYPE]
                    ?.enable = false
            }
        }
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
