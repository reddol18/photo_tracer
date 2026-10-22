package com.reddol18.phototracer.bench_app

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // adb shell am start ... --ez scan true 로 띄우면 갤러리 메타데이터만 읽어 파일로 남긴다
        if (intent?.getBooleanExtra("scan", false) == true) {
            worker.execute {
                try {
                    MetaScan(this).run()
                } catch (e: Throwable) {
                    Log.e("Bench", "메타 스캔 실패", e)
                }
            }
        }
        // --ez thumbs true: bench/thumbs.txt 의 사진만 작은 썸네일로 만든다
        if (intent?.getBooleanExtra("thumbs", false) == true) {
            worker.execute {
                try {
                    MetaScan(this).thumbs()
                } catch (e: Throwable) {
                    Log.e("Bench", "썸네일 실패", e)
                }
            }
        }
        // --es embed vision_384_w8.onnx: bench/embed.txt 의 사진 원본을 그 모델로 임베딩한다(진행은 logcat Bench:I)
        intent?.getStringExtra("embed")?.let { model ->
            worker.execute {
                try {
                    Benchmark(this) { line -> Log.i("Bench", line) }.embedMedia(model)
                } catch (e: Throwable) {
                    Log.e("Bench", "임베딩 실패", e)
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bench")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // adb shell am start ... --ez autorun true 로 띄우면 화면 조작 없이 바로 측정한다
                "autorun" -> result.success(intent?.getBooleanExtra("autorun", false) ?: false)
                "benchDir" -> result.success(Benchmark.benchDir(this).absolutePath)
                "run" -> worker.execute {
                    try {
                        val bench = Benchmark(this) { line -> main.post { channel.invokeMethod("progress", line) } }
                        val path = bench.run()
                        main.post { result.success(path) }
                    } catch (e: Throwable) {
                        Log.e("Bench", "측정 실패", e)
                        main.post { result.error("bench", e.toString(), e.stackTraceToString()) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
