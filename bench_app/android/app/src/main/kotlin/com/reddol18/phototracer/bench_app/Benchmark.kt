package com.reddol18.phototracer.bench_app

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PointF
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.FloatBuffer

/**
 * 0단계 속도 측정. 사진 폴더의 사진마다 디코드 → ML Kit 얼굴 검출 → SFace 임베딩 → SigLIP 이미지 임베딩
 * 시간을 재고, 결과 JSON을 bench/ 폴더에 쓴다. 설정은 bench/config.json (없으면 기본값).
 *
 * 폴더 구성 (adb push 로 넣는다, 앱 전용 외부 저장소라 권한이 필요 없다):
 *   /sdcard/Android/data/com.reddol18.phototracer.bench_app/files/bench/photos/  ← 사진
 *   /sdcard/Android/data/com.reddol18.phototracer.bench_app/files/bench/models/  ← ONNX
 */
class Benchmark(private val ctx: Context, private val progress: (String) -> Unit) {
    companion object {
        const val DETECT_LONG_SIDE = 1280 // PC 평가(extract_faces.py)와 같은 축소 크기
        const val MAX_FACES = 10
        const val SFACE = "face_recognition_sface_2021dec.onnx"

        // SFace(ArcFace) 정렬 기준점 112x112: 이미지 왼쪽 눈, 오른쪽 눈, 코, 입 왼쪽, 입 오른쪽
        val TEMPLATE = arrayOf(
            PointF(38.2946f, 51.6963f), PointF(73.5318f, 51.5014f), PointF(56.0252f, 71.7366f),
            PointF(41.5493f, 92.3655f), PointF(70.7299f, 92.2041f),
        )

        // 앱이 쓴 결과 파일은 앱 계정 전용(rw-rw----)이라 adb pull이 막힌다. 열 때마다 읽기 권한을 연다
        fun benchDir(ctx: Context): File = File(ctx.getExternalFilesDir(null), "bench").apply {
            mkdirs()
            listFiles()?.filter { it.name.startsWith("result_") }?.forEach { it.setReadable(true, false) }
        }
    }

    private val dir = benchDir(ctx)
    private val config = File(dir, "config.json").let { if (it.exists()) JSONObject(it.readText()) else JSONObject() }
    private val env = OrtEnvironment.getEnvironment()

    private fun session(file: File): OrtSession {
        val opts = OrtSession.SessionOptions()
        opts.setIntraOpNumThreads(config.optInt("threads", 4))
        opts.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        if (config.optBoolean("xnnpack", false)) {
            opts.addXnnpack(mapOf("intra_op_num_threads" to config.optInt("threads", 4).toString()))
        }
        return env.createSession(file.absolutePath, opts)
    }

    fun run(): String {
        val photos = File(dir, "photos").listFiles()
            ?.filter { it.isFile }?.sortedBy { it.name }?.take(config.optInt("limit", 1000)) ?: emptyList()
        require(photos.isNotEmpty()) { "사진이 없습니다: ${File(dir, "photos")}" }
        val models = File(dir, "models")
        val siglipNames = config.optJSONArray("siglip")?.let { a -> (0 until a.length()).map { a.getString(it) } }
            ?: models.listFiles()?.map { it.name }?.filter { it.startsWith("vision_") }?.sorted() ?: emptyList()
        val dump = config.optInt("dump", 10)

        val result = JSONObject()
        result.put("device", JSONObject().put("model", Build.MODEL).put("soc", Build.SOC_MODEL)
            .put("sdk", Build.VERSION.SDK_INT).put("cores", Runtime.getRuntime().availableProcessors()))
        result.put("config", config)
        result.put("start", state())

        val accurate = config.optString("mlkit", "fast") == "accurate"
        val detector = FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(if (accurate) FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE
                                    else FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
                .setMinFaceSize(0.05f)
                .build())

        val loads = JSONObject()
        fun timed(name: String, file: File): OrtSession {
            val t = System.nanoTime()
            val s = session(file)
            loads.put(name, ms(t))
            return s
        }
        val sface = File(models, SFACE).takeIf { it.exists() }?.let { timed(SFACE, it) }
        val siglip = siglipNames.map { it to timed(it, File(models, it)) }
        result.put("load_ms", loads)
        progress("모델 준비 완료: SFace ${if (sface != null) "있음" else "없음"}, SigLIP ${siglip.map { it.first }}")

        // 예열: 첫 실행은 메모리 할당 등으로 느리므로 기록에서 뺀다
        decode(photos[0])?.let { bmp ->
            Tasks.await(detector.process(InputImage.fromBitmap(bmp, 0)))
            sface?.let { embedFace(it, Bitmap.createScaledBitmap(bmp, 112, 112, true)) }
            siglip.forEach { (_, s) -> embedImage(s, bmp, resOf(s)) }
        }

        val rows = JSONArray()
        val embeddings = JSONObject()
        photos.forEachIndexed { i, file ->
            val row = JSONObject().put("photo", file.name)
            var t = System.nanoTime()
            val bmp = decode(file)
            row.put("decode_ms", ms(t))
            if (bmp == null) {
                rows.put(row.put("error", "decode")); return@forEachIndexed
            }
            row.put("w", bmp.width).put("h", bmp.height)

            t = System.nanoTime()
            val faces = Tasks.await(detector.process(InputImage.fromBitmap(bmp, 0)))
            row.put("mlkit_ms", ms(t)).put("faces", faces.size)
            row.put("boxes", JSONArray(faces.map { f ->
                val b = f.boundingBox
                JSONArray(listOf(b.left, b.top, b.width(), b.height()))
            }))

            if (sface != null) {
                t = System.nanoTime()
                var aligned = 0
                faces.take(MAX_FACES).forEach { f ->
                    val (crop, ok) = align(bmp, f)
                    if (ok) aligned++
                    embedFace(sface, crop)
                }
                row.put("sface_ms", ms(t)).put("aligned", aligned)
            }

            val sig = JSONObject()
            siglip.forEach { (name, s) ->
                t = System.nanoTime()
                val emb = embedImage(s, bmp, resOf(s))
                sig.put(name, ms(t))
                if (i < dump) embeddings.getOrCreate(name).put(file.name, JSONArray(emb.map { it.toDouble() }))
            }
            row.put("siglip_ms", sig)
            if (i % 10 == 0) row.put("state", state())
            rows.put(row)
            bmp.recycle()
            progress("${i + 1}/${photos.size} ${file.name} 얼굴 ${faces.size} · " +
                "검출 ${row.optDouble("mlkit_ms").toInt()}ms · " +
                siglip.joinToString(" ") { (n, _) -> "${n.removeSuffix(".onnx")} ${sig.optDouble(n).toInt()}ms" })
        }
        result.put("photos", rows).put("end", state()).put("embeddings", embeddings)

        val out = File(dir, "result_${System.currentTimeMillis()}.json")
        out.writeText(result.toString())
        out.setReadable(true, false)
        progress("완료: ${out.absolutePath}")
        detector.close(); sface?.close(); siglip.forEach { it.second.close() }
        return out.absolutePath
    }

    private fun JSONObject.getOrCreate(key: String): JSONObject =
        optJSONObject(key) ?: JSONObject().also { put(key, it) }

    private fun ms(start: Long) = (System.nanoTime() - start) / 1e6

    /** 발열·배터리 상태. 앱의 '바쁠 때 쉬기' 기준을 정하는 데 쓴다. */
    private fun state(): JSONObject {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        val battery = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        return JSONObject()
            .put("t", System.currentTimeMillis())
            .put("thermal", pm.currentThermalStatus)
            .put("battery_temp_c", (battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0) / 10.0)
            .put("battery_pct", battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1)
            .put("charging", (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0)
    }

    /** HEIC 포함 디코드(EXIF 회전 반영). 긴 변을 DETECT_LONG_SIDE 이하로 줄인다. */
    private fun decode(file: File): Bitmap? = try {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
            val long = maxOf(info.size.width, info.size.height)
            if (long > DETECT_LONG_SIDE) {
                val s = DETECT_LONG_SIDE.toFloat() / long
                decoder.setTargetSize((info.size.width * s).toInt(), (info.size.height * s).toInt())
            }
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE // 픽셀을 직접 읽어야 한다
        }
    } catch (e: Exception) {
        null
    }

    private fun resOf(s: OrtSession): Int = (s.inputInfo.values.first().info as ai.onnxruntime.TensorInfo).shape[2].toInt()

    /** SigLIP: 정사각형으로 늘려 리사이즈, RGB [-1, 1], NCHW */
    private fun embedImage(s: OrtSession, bmp: Bitmap, res: Int): FloatArray {
        val scaled = Bitmap.createScaledBitmap(bmp, res, res, true)
        val px = IntArray(res * res)
        scaled.getPixels(px, 0, res, 0, 0, res, res)
        val buf = FloatBuffer.allocate(3 * res * res)
        val plane = res * res
        for (i in px.indices) {
            val c = px[i]
            buf.put(i, ((c shr 16 and 0xFF) / 127.5f) - 1f)
            buf.put(plane + i, ((c shr 8 and 0xFF) / 127.5f) - 1f)
            buf.put(2 * plane + i, ((c and 0xFF) / 127.5f) - 1f)
        }
        if (scaled !== bmp) scaled.recycle()
        return run(s, buf, longArrayOf(1, 3, res.toLong(), res.toLong()))
    }

    /** SFace: 112x112 RGB, 0~255, NCHW (OpenCV FaceRecognizerSF 와 같은 입력) */
    private fun embedFace(s: OrtSession, crop: Bitmap): FloatArray {
        val px = IntArray(112 * 112)
        crop.getPixels(px, 0, 112, 0, 0, 112, 112)
        val buf = FloatBuffer.allocate(3 * 112 * 112)
        val plane = 112 * 112
        for (i in px.indices) {
            val c = px[i]
            buf.put(i, (c shr 16 and 0xFF).toFloat())
            buf.put(plane + i, (c shr 8 and 0xFF).toFloat())
            buf.put(2 * plane + i, (c and 0xFF).toFloat())
        }
        return run(s, buf, longArrayOf(1, 3, 112, 112))
    }

    private fun run(s: OrtSession, buf: FloatBuffer, shape: LongArray): FloatArray {
        OnnxTensor.createTensor(env, buf, shape).use { input ->
            s.run(mapOf(s.inputNames.first() to input)).use { out ->
                @Suppress("UNCHECKED_CAST")
                return (out[0].value as Array<FloatArray>)[0]
            }
        }
    }

    /**
     * ML Kit 랜드마크 5점을 SFace 기준점에 맞추는 닮음 변환으로 112x112 얼굴을 잘라낸다.
     * ML Kit의 LEFT/RIGHT는 '사람 기준'이라 이미지 왼쪽 눈 = RIGHT_EYE 다. 점이 모자라면 상자만 잘라 쓴다.
     */
    private fun align(bmp: Bitmap, face: Face): Pair<Bitmap, Boolean> {
        val types = intArrayOf(FaceLandmark.RIGHT_EYE, FaceLandmark.LEFT_EYE, FaceLandmark.NOSE_BASE,
                               FaceLandmark.MOUTH_RIGHT, FaceLandmark.MOUTH_LEFT)
        val src = types.map { face.getLandmark(it)?.position }
        val out = Bitmap.createBitmap(112, 112, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val m = Matrix()
        val ok = src.all { it != null }
        if (ok) {
            // 최소제곱 닮음 변환: q = [a -b; b a] p + t
            val p = src.map { it!! }
            val pm = PointF(p.map { it.x }.average().toFloat(), p.map { it.y }.average().toFloat())
            val qm = PointF(TEMPLATE.map { it.x }.average().toFloat(), TEMPLATE.map { it.y }.average().toFloat())
            var sxx = 0.0; var sxy = 0.0; var norm = 0.0
            for (k in p.indices) {
                val px = p[k].x - pm.x; val py = p[k].y - pm.y
                val qx = TEMPLATE[k].x - qm.x; val qy = TEMPLATE[k].y - qm.y
                sxx += px * qx + py * qy
                sxy += px * qy - py * qx
                norm += px * px + py * py
            }
            val a = (sxx / norm).toFloat(); val b = (sxy / norm).toFloat()
            m.setValues(floatArrayOf(a, -b, qm.x - (a * pm.x - b * pm.y),
                                     b, a, qm.y - (b * pm.x + a * pm.y), 0f, 0f, 1f))
        } else {
            val r = face.boundingBox
            m.setRectToRect(android.graphics.RectF(r), android.graphics.RectF(0f, 0f, 112f, 112f),
                            Matrix.ScaleToFit.FILL)
        }
        canvas.drawBitmap(bmp, m, Paint(Paint.FILTER_BITMAP_FLAG))
        return out to ok
    }
}
