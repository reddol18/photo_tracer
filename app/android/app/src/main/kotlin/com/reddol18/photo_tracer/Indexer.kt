package com.reddol18.photo_tracer

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.PowerManager
import android.util.Log
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 밤 작업 본체. 사진을 한 장씩 한 번만 디코드해 얼굴(모든 사진)과 장면 벡터(대표 사진·구간 밖 사진)를 함께 만든다.
 * 한 장 끝날 때마다 DB에 쓰므로 언제 끊겨도 다음에 이어 한다.
 * 순서: 찍은 날을 아는 사진(최근 것부터) → 구간 밖 사진. 첫날 밤 뒤에 사람·날짜 있는 사진 검색부터 쓸 수 있게.
 * 쉬기 (0단계: 발열 상태가 0인 채로 속도만 절반이 된 '조용한 감속'이 있었다):
 *   발열 상태 MODERATE 이상, 배터리 42℃ 이상, 최근 장면 벡터 시간이 처음의 1.8배를 넘으면 2분 쉰다.
 * mode "night": 충전이 끊기면 멈추고, 화면이 켜져 있으면(폰을 쓰는 중) 기다린다. "now": 시험용, 둘 다 무시.
 */
class Indexer(
    private val ctx: Context,
    private val mode: String,
    private val stopped: () -> Boolean,
    private val progress: (done: Int, total: Int) -> Unit,
) {
    companion object {
        const val REST_MS = 120_000L
        const val TEMP_LIMIT = 42.0
        const val SLOW = 1.8
        const val USER_STOP = "사용자가 멈춤"
        // 얼굴이 있는데 벡터가 옛 방식인 사진 (얼굴 없는 사진은 다시 볼 것이 없다)
        private val OLD_FACES = "(p.faces_done = 1 AND p.face_ver < ${Models.FACE_VER} AND EXISTS (SELECT 1 FROM faces WHERE photo_id = p.id))"
        private const val SAME_FACE_IOU = 0.5f
        private val running = AtomicBoolean(false)
        private val userStop = AtomicBoolean(false)
        fun isRunning() = running.get()
        /** 도는 작업의 mode (안 돌면 null) */
        @Volatile var runningMode: String? = null
            private set
        /** 멈춤 버튼: 도는 작업(밤·시험)을 다음 장 전에 끝낸다. 밤 일정은 남아 다음 충전 때 다시 깨어난다 */
        fun requestStop() = userStop.set(true)
    }

    private val db = Db.get(ctx)
    private val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
    private var runId = 0L
    private var rests = 0
    private var maxTemp = 0.0
    private val faceMs = ArrayList<Double>()
    private val vecMs = ArrayList<Double>()
    private var photos = 0
    private var faces = 0
    private var vectors = 0

    /** reembed: 얼굴은 찾아 두었지만 벡터가 옛 방식(face_ver < FACE_VER) — 얼굴 줄(정답 표시)은 두고 벡터만 바꾼다 */
    private class Job(val id: Long, val faces: Boolean, val vector: Boolean, val reembed: Boolean)
    private var reembedded = 0

    /** 반환: 멈춘 이유 */
    fun run(note: String): String {
        if (!running.compareAndSet(false, true)) return "이미 실행 중"
        userStop.set(false)
        runningMode = mode
        runId = db.writableDatabase.insert("runs", null, ContentValues().apply {
            put("mode", mode); put("start", now()); put("last", now()); put("note", note)
        })
        var stop = "오류"
        try {
            stop = loop()
            // 얼굴 벡터를 다시 만들었으면 묶음 중심도 옛 벡터라 처음부터 다시 묶는다
            if (reembedded > 0 && stop == "완료") People(ctx).full()
            if (stop == "완료") { People(ctx).cluster(); Who(ctx).assignAll() }
        } catch (e: Throwable) {
            Log.e("PhotoTracer", "밤 작업 오류", e)
            stop = "오류: ${e.javaClass.simpleName} ${e.message?.take(80)}"
        } finally {
            save(stop)
            runningMode = null
            running.set(false)
        }
        return stop
    }

    /** WorkManager가 멈출 때 이유를 남긴다(run이 끝난 뒤 덧씀) */
    fun stoppedBy(reason: String) {
        if (runId > 0) db.writableDatabase.execSQL("UPDATE runs SET stop = ? WHERE id = ?", arrayOf<Any>(reason, runId))
    }

    /** 아직 얼굴이나 장면 벡터를 안 만든 사진이 있나 */
    fun hasWork(): Boolean = pending().isNotEmpty()

    private fun pending(): List<Job> {
        val jobs = ArrayList<Job>()
        db.readableDatabase.rawQuery("""
            SELECT p.id, p.faces_done = 0, ${Db.NEEDS_VECTOR} AND v.photo_id IS NULL, $OLD_FACES
            FROM photos p LEFT JOIN vectors v ON v.photo_id = p.id
            WHERE p.failed = 0 AND (p.faces_done = 0 OR (${Db.NEEDS_VECTOR} AND v.photo_id IS NULL) OR $OLD_FACES)
            ORDER BY p.segment IS NULL, COALESCE(p.taken_at, p.received_at, 0) DESC""", null).use {
            while (it.moveToNext()) jobs.add(Job(it.getLong(0), it.getInt(1) == 1, it.getInt(2) == 1, it.getInt(3) == 1))
        }
        return jobs
    }

    /**
     * 개발용: 앱 폴더에 debug_crops.txt(줄마다 사진 id)를 adb로 넣으면 그 사진들의 SFace 입력(정렬한 112×112 얼굴)을
     * debug_crops/<id>_<n>.png 로 쓰고 txt를 지운다. info.txt: 비트맵 형식, 랜드마크 5점이 다 있었나, 상자
     */
    private fun debugCrops() {
        val dir = ctx.getExternalFilesDir(null) ?: return
        val list = File(dir, "debug_crops.txt").takeIf { it.exists() } ?: return
        val out = File(dir, "debug_crops").apply { mkdirs() }
        val models = Models(ctx)
        val detector = models.detector()
        val info = StringBuilder()
        try {
            for (id in list.readLines().mapNotNull { it.trim().toLongOrNull() }) {
                val bmp = models.decode(id) ?: continue
                models.faces(detector, bmp).forEachIndexed { k, f ->
                    val (crop, five) = models.align(bmp, f)
                    File(out, "${id}_$k.png").outputStream().use { crop.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                    val lm = listOf(com.google.mlkit.vision.face.FaceLandmark.LEFT_EYE, com.google.mlkit.vision.face.FaceLandmark.RIGHT_EYE,
                        com.google.mlkit.vision.face.FaceLandmark.NOSE_BASE, com.google.mlkit.vision.face.FaceLandmark.MOUTH_LEFT,
                        com.google.mlkit.vision.face.FaceLandmark.MOUTH_RIGHT)
                        .joinToString(" ") { t -> f.getLandmark(t)?.position?.let { "${it.x.toInt()}:${it.y.toInt()}" } ?: "-" }
                    info.append("$id,$k,${bmp.config},${bmp.width}x${bmp.height},five=$five,box=${f.boundingBox},L_R_N_ML_MR=$lm\n")
                }
                bmp.recycle()
            }
        } finally { detector.close() }
        File(out, "info.txt").writeText(info.toString())
        list.delete()
    }

    private fun loop(): String {
        try { debugCrops() } catch (e: Exception) { Log.w("PhotoTracer", "debug_crops 실패: $e") }
        val jobs = pending()
        if (jobs.isEmpty()) return "완료"
        val models = Models(ctx)
        val detector = models.detector()
        val sface = models.session(Models.SFACE)
        val vision = if (jobs.any { it.vector }) models.session(Models.VISION) else null
        try {
            for ((i, job) in jobs.withIndex()) {
                halt()?.let { return it }
                rest()?.let { return it }
                halt()?.let { return it }
                process(models, detector, sface, vision, job)
                progress(i + 1, jobs.size)
                if ((i + 1) % 10 == 0) save(null)
            }
        } finally {
            detector.close(); sface.close(); vision?.close()
        }
        return "완료"
    }

    private fun process(models: Models, detector: com.google.mlkit.vision.face.FaceDetector,
                        sface: ai.onnxruntime.OrtSession, vision: ai.onnxruntime.OrtSession?, job: Job) {
        val w = db.writableDatabase
        val bmp = models.decode(job.id)
        if (bmp == null) {
            w.execSQL("UPDATE photos SET failed = 1 WHERE id = ?", arrayOf(job.id))
            return
        }
        try {
            if (job.reembed && !job.faces) reembed(models, detector, sface, bmp, job) // 장면 벡터도 필요하면 아래에서 이어 만든다
            val rows = ArrayList<ContentValues>()
            if (job.faces) {
                val t = System.nanoTime()
                for (f in models.faces(detector, bmp)) {
                    val b = f.boundingBox
                    rows.add(ContentValues().apply {
                        put("photo_id", job.id)
                        put("x", b.left.toDouble() / bmp.width); put("y", b.top.toDouble() / bmp.height)
                        put("w", b.width().toDouble() / bmp.width); put("h", b.height().toDouble() / bmp.height)
                        put("v", Db.blob(models.embedFace(sface, bmp, f)))
                    })
                }
                faceMs.add(ms(t))
            }
            var vec: FloatArray? = null
            if (job.vector && vision != null) {
                val t = System.nanoTime()
                vec = models.embedImage(vision, bmp)
                vecMs.add(ms(t))
            }
            w.beginTransaction()
            try {
                if (job.faces) {
                    w.delete("faces", "photo_id = ?", arrayOf(job.id.toString()))
                    rows.forEach { w.insert("faces", null, it) }
                    w.execSQL("UPDATE photos SET faces_done = 1, face_ver = ? WHERE id = ?", arrayOf<Any>(Models.FACE_VER, job.id))
                }
                vec?.let { w.insertWithOnConflict("vectors", null, ContentValues().apply {
                    put("photo_id", job.id); put("v", Db.blob(it))
                }, android.database.sqlite.SQLiteDatabase.CONFLICT_REPLACE) }
                w.setTransactionSuccessful()
            } finally { w.endTransaction() }
            photos++
            faces += rows.size
            if (vec != null) vectors++
        } finally {
            bmp.recycle()
        }
    }

    /**
     * 얼굴 벡터만 다시 만든다. 같은 디코드·같은 검출이라 얼굴 상자가 그대로 나온다 → 저장된 얼굴과 상자 겹침(IoU)으로 짝지어
     * 그 줄의 벡터만 바꾼다(얼굴 id가 그대로라 정답·아님 표시가 남는다). 짝 없는 옛 얼굴은 표시가 없으면 지우고, 새로 나온 얼굴은 넣는다.
     */
    private fun reembed(models: Models, detector: com.google.mlkit.vision.face.FaceDetector,
                        sface: ai.onnxruntime.OrtSession, bmp: android.graphics.Bitmap, job: Job) {
        val t = System.nanoTime()
        class Old(val id: Long, val x: Double, val y: Double, val w: Double, val h: Double)
        val old = ArrayList<Old>()
        db.readableDatabase.rawQuery("SELECT id, x, y, w, h FROM faces WHERE photo_id = ?", arrayOf(job.id.toString())).use {
            while (it.moveToNext()) old.add(Old(it.getLong(0), it.getDouble(1), it.getDouble(2), it.getDouble(3), it.getDouble(4)))
        }
        fun iou(o: Old, x: Double, y: Double, w: Double, h: Double): Double {
            val ix = maxOf(0.0, minOf(o.x + o.w, x + w) - maxOf(o.x, x)); val iy = maxOf(0.0, minOf(o.y + o.h, y + h) - maxOf(o.y, y))
            val i = ix * iy
            return i / (o.w * o.h + w * h - i)
        }
        val wdb = db.writableDatabase
        val left = old.toMutableList()
        val updates = ArrayList<Pair<Long, ByteArray>>(); val inserts = ArrayList<ContentValues>()
        for (f in models.faces(detector, bmp)) {
            val b = f.boundingBox
            val x = b.left.toDouble() / bmp.width; val y = b.top.toDouble() / bmp.height
            val w = b.width().toDouble() / bmp.width; val h = b.height().toDouble() / bmp.height
            val v = Db.blob(models.embedFace(sface, bmp, f))
            val match = left.maxByOrNull { iou(it, x, y, w, h) }?.takeIf { iou(it, x, y, w, h) >= SAME_FACE_IOU }
            if (match != null) { left.remove(match); updates.add(match.id to v) }
            else inserts.add(ContentValues().apply {
                put("photo_id", job.id); put("x", x); put("y", y); put("w", w); put("h", h); put("v", v)
            })
        }
        faceMs.add(ms(t))
        wdb.beginTransaction()
        try {
            for ((id, v) in updates) wdb.execSQL("UPDATE faces SET v = ? WHERE id = ?", arrayOf<Any>(v, id))
            inserts.forEach { wdb.insert("faces", null, it) }
            for (o in left) wdb.execSQL("DELETE FROM faces WHERE id = ? AND id NOT IN (SELECT face_id FROM face_marks)", arrayOf<Any>(o.id))
            wdb.execSQL("UPDATE photos SET face_ver = ? WHERE id = ?", arrayOf<Any>(Models.FACE_VER, job.id))
            wdb.setTransactionSuccessful()
        } finally { wdb.endTransaction() }
        if (left.isNotEmpty() || inserts.isNotEmpty()) Log.i("PhotoTracer", "얼굴 다시 만듦 ${job.id}: 그대로 ${updates.size}, 새로 ${inserts.size}, 짝 없음 ${left.size}")
        faces += updates.size + inserts.size; reembedded++
    }

    /** 쉬어야 하면 쉬고 null, 멈춰야 하면 이유 */
    private fun rest(): String? {
        while (true) {
            val battery = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val temp = (battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0) / 10.0
            maxTemp = maxOf(maxTemp, temp)
            val charging = (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
            if (mode == "night" && !charging) return "충전 끊김"
            val why = when {
                mode == "night" && pm.isInteractive -> "사용 중"
                pm.currentThermalStatus >= PowerManager.THERMAL_STATUS_MODERATE -> "발열 상태 ${pm.currentThermalStatus}"
                temp >= TEMP_LIMIT -> "배터리 ${temp}℃"
                slow() -> "속도 저하"
                else -> return null
            }
            Log.i("PhotoTracer", "쉬기: $why")
            if (why != "사용 중") rests++
            val until = System.currentTimeMillis() + (if (why == "사용 중") 30_000L else REST_MS)
            while (System.currentTimeMillis() < until) {
                halt()?.let { return it }
                Thread.sleep(5_000)
            }
            if (why == "속도 저하") vecMs.subList(maxOf(10, vecMs.size - 10), vecMs.size).clear() // 쉰 뒤 새로 잰다
        }
    }

    private fun halt(): String? = when {
        userStop.get() -> USER_STOP
        stopped() -> "시스템이 멈춤"
        else -> null
    }

    /** 최근 10장 장면 벡터 시간 중앙값이 처음 10장의 SLOW배를 넘나 */
    private fun slow(): Boolean {
        if (vecMs.size < 20) return false
        return median(vecMs.takeLast(10)) > SLOW * median(vecMs.take(10))
    }

    private fun save(stop: String?) {
        if (runId <= 0) return
        db.writableDatabase.update("runs", ContentValues().apply {
            put("last", now()); put("photos", photos); put("faces", faces); put("vectors", vectors)
            put("face_ms", if (faceMs.isEmpty()) null else median(faceMs))
            put("vec_ms", if (vecMs.isEmpty()) null else median(vecMs))
            put("rests", rests); put("max_temp", maxTemp)
            if (stop != null) { put("end", now()); put("stop", stop) }
        }, "id = ?", arrayOf(runId.toString()))
    }

    private fun median(v: List<Double>) = v.sorted()[v.size / 2]
    private fun ms(start: Long) = (System.nanoTime() - start) / 1e6
    private fun now() = System.currentTimeMillis()
}
