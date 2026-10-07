allprojects {
    repositories {
        google()
        mavenCentral()
        // 学习通签到取 OAID 用的 Android_CN_OAID 只发布在 JitPack，它依赖的华为、荣耀广告标识 SDK 在各自厂商仓库。
        maven { url = uri("https://jitpack.io") }
        maven { url = uri("https://developer.huawei.com/repo") }
        maven { url = uri("https://developer.hihonor.com/repo") }
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
