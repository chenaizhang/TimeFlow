import com.android.build.api.dsl.LibraryExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile
import org.gradle.api.tasks.compile.JavaCompile

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

subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<LibraryExtension>("android") {
            if (compileSdk == null || (compileSdk ?: 0) < 34) {
                compileSdk = 34
            }
            if (namespace == null) {
                namespace = "dev.timeflow.${project.name.replace('-', '_')}"
            }
        }
        afterEvaluate {
            tasks.withType<KotlinJvmCompile>().configureEach {
                val javaTaskName = name.replace("Kotlin", "JavaWithJavac")
                val javaTarget =
                    (tasks.findByName(javaTaskName) as? JavaCompile)
                        ?.targetCompatibility
                        ?.trim()
                        ?.ifEmpty { null }
                val resolvedTarget = when (javaTarget) {
                    "1.8", "8" -> JvmTarget.JVM_1_8
                    "9" -> JvmTarget.JVM_9
                    "10" -> JvmTarget.JVM_10
                    "11" -> JvmTarget.JVM_11
                    "12" -> JvmTarget.JVM_12
                    "13" -> JvmTarget.JVM_13
                    "14" -> JvmTarget.JVM_14
                    "15" -> JvmTarget.JVM_15
                    "16" -> JvmTarget.JVM_16
                    "17" -> JvmTarget.JVM_17
                    "18" -> JvmTarget.JVM_18
                    "19" -> JvmTarget.JVM_19
                    "20" -> JvmTarget.JVM_20
                    "21" -> JvmTarget.JVM_21
                    else -> JvmTarget.JVM_11
                }
                compilerOptions.jvmTarget.set(resolvedTarget)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
