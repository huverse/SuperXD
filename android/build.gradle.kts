// 第三方仓库只许提供各自该给的组（供应链）：按仓库地址限定，插件自己再声明的同一仓库也一并限定
// （image_cropper 会往所有工程再加一个不设限的 JitPack）。新增依赖走这几个仓库时要在这里登记它的组。
val thirdPartyRepositoryGroups =
    mapOf(
        // OAID 库与 image_cropper 依赖的 uCrop。
        "jitpack.io" to listOf("com.github.gzu-liyujiang", "com.github.Yalantis"),
        "developer.huawei.com" to listOf("com.huawei.hms"),
        "developer.hihonor.com" to listOf("com.hihonor.mcs"),
    )

allprojects {
    repositories {
        google()
        mavenCentral()
        // 学习通签到取 OAID 用的 Android_CN_OAID 只发布在 JitPack，它依赖的华为、荣耀广告标识 SDK 在各自厂商仓库。
        maven { url = uri("https://jitpack.io") }
        maven { url = uri("https://developer.huawei.com/repo") }
        maven { url = uri("https://developer.hihonor.com/repo") }
        configureEach {
            val groups = (this as? MavenArtifactRepository)?.let { thirdPartyRepositoryGroups[it.url.host] } ?: return@configureEach
            content { groups.forEach { group -> includeGroup(group) } }
        }
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
