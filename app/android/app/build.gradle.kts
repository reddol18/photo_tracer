plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.reddol18.photo_tracer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.reddol18.photo_tracer"
        // ImageDecoder(HEIC)·열 상태 API. 최소 지원 버전은 버전별 사용 비율을 확인한 뒤 정한다
        minSdk = 29
        ndk { abiFilters += listOf("arm64-v8a") }
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 모델은 첫 실행 때 앱 폴더로 복사해 ONNX Runtime에 경로로 넘긴다. 압축하지 않아야 복사가 빠르다
    androidResources {
        noCompress += listOf("onnx")
    }

    // abiFilters는 Flutter가 덮어써 ONNX Runtime·ML Kit의 다른 ABI 라이브러리(약 75MB)가 남는다 — 패키징에서 뺀다
    packaging {
        jniLibs { excludes += listOf("lib/x86/**", "lib/x86_64/**", "lib/armeabi-v7a/**") }
    }

    buildTypes {
        release {
            // 미니 앱은 adb로 직접 설치한다. Play에 올릴 때 서명 설정을 따로 만든다
            signingConfig = signingConfigs.getByName("debug")
            // R8이 ONNX Runtime·ML Kit의 JNI/리플렉션 클래스를 지우지 않게 끈다
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    testOptions {
        unitTests.all {
            it.testLogging { showStandardStreams = true }
            it.jvmArgs("-Dstdout.encoding=UTF-8", "-Dfile.encoding=UTF-8")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.mlkit:face-detection:16.1.7")
    // PC 검증(poc/, onnxruntime 1.31)과 같은 버전 — 가중치 8비트(MatMulNBits) 커널 차이를 없앤다
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.31.0")
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    testImplementation("junit:junit:4.13.2")
}
