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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// ★ 2026-11-05 统一所有子项目的 compileSdk = 36
// 原因：file_picker 8.3.7 写死 compileSdk 34，但 flutter_plugin_android_lifecycle
// 要求 >= 36。这里在 AGP 插件应用后立即抬升，不改 pub-cache 源码。
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
            compileSdk = 36
        }
    }
    plugins.withId("com.android.application") {
        extensions.configure<com.android.build.gradle.AppExtension>("android") {
            compileSdkVersion(36)
        }
    }
}
