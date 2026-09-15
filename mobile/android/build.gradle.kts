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
// another_telephony declares Kotlin jvmTarget 1.8 while AGP compiles its Java
// at 11, and AGP 9 rejects that pair outright ("Inconsistent JVM Target
// Compatibility"). Rather than pick a number and hope every plugin agrees,
// align each plugin's Kotlin target to the Java target AGP actually gave it.
//
// :app is excluded -- it sets both sides to 17 explicitly in
// app/build.gradle.kts, and reading its Java target back here would just be
// a slower way of arriving at the same answer.
//
// Registered before the evaluationDependsOn(":app") block below: that one
// forces :app to evaluate immediately, and afterEvaluate on an
// already-evaluated project is an error.
subprojects {
    if (name == "app") return@subprojects
    afterEvaluate {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            val javaTarget = tasks.withType<JavaCompile>().firstOrNull()?.targetCompatibility
            if (javaTarget != null) {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(javaTarget))
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
