import com.android.build.gradle.BaseExtension

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

// 统一所有子项目（含插件）的 compileSdk ≥ 36：desktop_drop 等插件默认
// 编译 android-33，而其依赖的 androidx 库要求 34+，否则 AAR 元数据检查
// 失败（"15 issues were found when checking AAR metadata"）。
subprojects {
    afterEvaluate {
        val androidExt = project.extensions.findByName("android")
        if (androidExt is BaseExtension) {
            androidExt.compileSdkVersion(36)
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
