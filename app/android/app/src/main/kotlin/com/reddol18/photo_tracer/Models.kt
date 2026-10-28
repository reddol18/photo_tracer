package com.reddol18.photo_tracer

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.RectF
import android.provider.MediaStore
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import java.io.File
import java.nio.FloatBuffer
import java.nio.LongBuffer

/**
 * 모델 묶음. 전처리는 0단계 측정 앱(bench_app Benchmark.kt)과 똑같이 둔다 — 그 결과로 검색 정확도를 쟀다.
 * 모델 파일은 APK assets/models 에 있고, 처음 쓸 때 앱 폴더로 복사해 경로로 연다(수백 MB라 메모리로 읽지 않는다).
 * 세션은 쓰는 쪽이 필요할 때 열고 닫는다: 밤 작업은 사진·얼굴 모델, 검색 화면은 텍스트 모델.
 */
class Models(private val ctx: Context) {
    companion object {
        const val VISION = "vision_384_w8.onnx"
        const val TEXT = "text_w8.onnx"
        const val SFACE = "face_recognition_sface_2021dec.onnx"
        const val FACE_VER = 2 // 얼굴 벡터 만드는 방식이 바뀌면 올린다 → 밤 작업이 얼굴 벡터를 다시 만든다 (2: 랜드마크 좌우)
        const val DETECT_LONG_SIDE = 1280 // PC 평가(extract_faces.py)와 같은 축소 크기
        const val MAX_FACES = 10
        const val MIN_FACE_PX = 32 // 이보다 작은 얼굴은 벡터가 흐려 묶음을 망친다
        const val THREADS = 4

        // SFace(ArcFace) 정렬 기준점 112x112: 이미지 왼쪽 눈, 오른쪽 눈, 코, 입 왼쪽, 입 오른쪽
        val TEMPLATE = arrayOf(
            PointF(38.2946f, 51.6963f), PointF(73.5318f, 51.5014f), PointF(56.0252f, 71.7366f),
            PointF(41.5493f, 92.3655f), PointF(70.7299f, 92.2041f),
        )
        private val copyLock = Any()
    }

    val env: OrtEnvironment = OrtEnvironment.getEnvironment()

    /** assets/models/<name> 을 앱 폴더로 복사(크기가 다르면 다시) 하고 경로를 준다 */
    fun file(name: String): File = synchronized(copyLock) {
        val dst = File(File(ctx.filesDir, "models").apply { mkdirs() }, name)
        val size = ctx.assets.openFd("models/$name").use { it.length }
        if (!dst.exists() || dst.length() != size) {
            val tmp = File(dst.path + ".tmp")
            ctx.assets.open("models/$name").use { input -> tmp.outputStream().use { input.copyTo(it, 1 shl 20) } }
            tmp.renameTo(dst)
        }
        dst
    }

    fun session(name: String): OrtSession {
        val opts = OrtSession.SessionOptions()
        opts.setIntraOpNumThreads(THREADS)
        opts.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        return env.createSession(file(name).absolutePath, opts)
    }

    fun detector(): FaceDetector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
            .setMinFaceSize(0.05f)
            .build())

    fun tokenizer(): Tokenizer = Tokenizer(ctx.assets.open("tokenizer/vocab.txt"), ctx.assets.open("tokenizer/merges.txt"))

    /** HEIC 포함 디코드(EXIF 회전 반영). 긴 변을 DETECT_LONG_SIDE 이하로 줄인다. 읽을 수 없으면 null */
    fun decode(id: Long): Bitmap? = try {
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ctx.contentResolver, uri)) { decoder, info, _ ->
            val long = maxOf(info.size.width, info.size.height)
            if (long > DETECT_LONG_SIDE) {
                val s = DETECT_LONG_SIDE.toFloat() / long
                decoder.setTargetSize((info.size.width * s).toInt().coerceAtLeast(1), (info.size.height * s).toInt().coerceAtLeast(1))
            }
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE // 픽셀을 직접 읽어야 한다
        }
    } catch (e: Exception) {
        null
    }

    fun faces(detector: FaceDetector, bmp: Bitmap): List<Face> =
        Tasks.await(detector.process(InputImage.fromBitmap(bmp, 0)))
            .filter { minOf(it.boundingBox.width(), it.boundingBox.height()) >= MIN_FACE_PX }
            .sortedByDescending { it.boundingBox.width() * it.boundingBox.height() }
            .take(MAX_FACES)

    /** SigLIP: 정사각형으로 늘려 리사이즈, RGB [-1, 1], NCHW. 출력은 정규화된 768차원 */
    fun embedImage(s: OrtSession, bmp: Bitmap): FloatArray {
        val res = (s.inputInfo.values.first().info as ai.onnxruntime.TensorInfo).shape[2].toInt()
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
        return run(s, OnnxTensor.createTensor(env, buf, longArrayOf(1, 3, res.toLong(), res.toLong())))
    }

    /** SFace: 정렬한 112x112 얼굴, RGB 0~255, NCHW (OpenCV FaceRecognizerSF 와 같은 입력). 출력을 정규화해 준다 */
    fun embedFace(s: OrtSession, bmp: Bitmap, face: Face): FloatArray {
        val crop = align(bmp, face).first
        val px = IntArray(112 * 112)
        crop.getPixels(px, 0, 112, 0, 0, 112, 112)
        crop.recycle()
        val buf = FloatBuffer.allocate(3 * 112 * 112)
        val plane = 112 * 112
        for (i in px.indices) {
            val c = px[i]
            buf.put(i, (c shr 16 and 0xFF).toFloat())
            buf.put(plane + i, (c shr 8 and 0xFF).toFloat())
            buf.put(2 * plane + i, (c and 0xFF).toFloat())
        }
        val v = run(s, OnnxTensor.createTensor(env, buf, longArrayOf(1, 3, 112, 112)))
        val n = kotlin.math.sqrt(v.sumOf { (it * it).toDouble() }).toFloat()
        return FloatArray(v.size) { v[it] / n }
    }

    /** 검색어 → 정규화된 768차원 벡터 */
    fun embedText(s: OrtSession, ids: LongArray): FloatArray =
        run(s, OnnxTensor.createTensor(env, LongBuffer.wrap(ids), longArrayOf(1, ids.size.toLong())))

    private fun run(s: OrtSession, input: OnnxTensor): FloatArray = input.use {
        s.run(mapOf(s.inputNames.first() to it)).use { out ->
            @Suppress("UNCHECKED_CAST")
            (out[0].value as Array<FloatArray>)[0]
        }
    }

    /**
     * ML Kit 랜드마크 5점을 SFace 기준점에 맞추는 닮음 변환으로 112x112 얼굴을 잘라낸다. 점이 모자라면 상자만 잘라 쓴다.
     * ML Kit의 LEFT_EYE·MOUTH_LEFT는 이미지 왼쪽에 있다(폰에서 좌표로 확인). 처음엔 '사람 기준'으로 알고 거꾸로 맞춰서
     * 닮음 변환이 좌우 뒤집힌 점들에 맞추느라 얼굴이 작게 기울어진 채 장면이 들어갔고, 같은 사람·다른 사람 유사도가 똑같았다
     * (정답 얼굴끼리 중앙값 0.356 대 0.360). 고친 뒤 얼굴 벡터를 모두 다시 만든다(FACE_VER).
     */
    fun align(bmp: Bitmap, face: Face): Pair<Bitmap, Boolean> {
        val types = intArrayOf(FaceLandmark.LEFT_EYE, FaceLandmark.RIGHT_EYE, FaceLandmark.NOSE_BASE,
                               FaceLandmark.MOUTH_LEFT, FaceLandmark.MOUTH_RIGHT)
        val src = types.map { face.getLandmark(it)?.position }
        val out = Bitmap.createBitmap(112, 112, Bitmap.Config.ARGB_8888)
        val m = Matrix()
        if (src.all { it != null }) {
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
            m.setRectToRect(RectF(face.boundingBox), RectF(0f, 0f, 112f, 112f), Matrix.ScaleToFit.FILL)
        }
        Canvas(out).drawBitmap(bmp, m, Paint(Paint.FILTER_BITMAP_FLAG))
        return out to src.all { it != null } // 두 번째: 랜드마크 5점으로 정렬했나(아니면 상자만)
    }
}
