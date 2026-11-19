plugins {
    kotlin("multiplatform") version "2.4.20"
}

kotlin {
    jvm()
    listOf(iosArm64(), iosSimulatorArm64(), iosX64()).forEach { target ->
        target.binaries.framework {
            baseName = "WheelCore"
            isStatic = true
        }
    }
    sourceSets {
        commonMain.dependencies {
            implementation("io.github.tritbool:euc-ble-session:0.1.3")
            implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.7.1")
        }
        jvmTest.dependencies {
            implementation(kotlin("test-junit"))
        }
    }
}
