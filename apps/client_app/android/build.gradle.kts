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
// on 17 or lower, and Kotlin fails the build on the mismatch. stripe_android is
// the first to hit it: its build script sets jvmTarget only on AGP < 9, and
// expects Built-in Kotlin to derive it from compileOptions otherwise, which
// never happens because we set android.builtInKotlin=false. Pin both compilers
// on every module instead of chasing each plugin.
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
        }
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// stripe_android declares Stripe's issuing push-provisioning SDK compileOnly
// (optional, unused here), but release lint still resolves it transitively,
// and its play-services-tapandpay dependency is only distributed privately by
// Google, so resolution fails. Nothing in the app needs it.
subprojects {
    configurations.configureEach {
        exclude(group = "com.google.android.gms", module = "play-services-tapandpay")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
