package com.reddol18.photo_tracer

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.PowerManager
import android.util.Log
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
        private val running = AtomicBoolean(false)
        private val userStop = AtomicBoolean(false)
        fun isRunning() = running.get()
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

    private class Job(val id: Long, val faces: Boolean, val vector: Boolean)

    /** 반환: 멈춘 이유 */
    fun run(note: String): String {
        if (!running.compareAndSet(false, true)) return "이미 실행 중"
        userStop.set(false)
        runId = db.writableDatabase.insert("runs", null, ContentValues().apply {
            put("mode", mode); put("start", now()); put("last", now()); put("note", note)
        })
        var stop = "오류"
        try {
            stop = loop()
            if (stop == "완료") People(ctx).cluster()
        } catch (e: Throwable) {
            Log.e("PhotoTracer", "밤 작업 오류", e)
            stop = "오류: ${e.javaClass.simpleName} ${e.message?.take(80)}"
        } finally {
            save(stop)
            running.set(false)
        }
        return stop
    }

    /** WorkManager가 멈출 때 이유를 남긴다(run이 끝난 뒤 덧씀) */
    fun stoppedBy(reason: String) {
        if (runId > 0) db.writableDatabase.execSQL("UPDATE runs SET stop = ? WHERE id = ?", arrayOf<Any>(reason, runId))
    }

    private fun loop(): String {
        val jobs = ArrayList<Job>()
        db.readableDatabase.rawQuery("""
            SELECT p.id, p.faces_done = 0, ${Db.NEEDS_VECTOR} AND v.photo_id IS NULL
            FROM photos p LEFT JOIN vectors v ON v.photo_id = p.id
            WHERE p.failed = 0 AND (p.faces_done = 0 OR (${Db.NEEDS_VECTOR} AND v.photo_id IS NULL))
            ORDER BY p.segment IS NULL, COALESCE(p.taken_at, p.received_at, 0) DESC""", null).use {
            while (it.moveToNext()) jobs.add(Job(it.getLong(0), it.getInt(1) == 1, it.getInt(2) == 1))
        }
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
                    w.execSQL("UPDATE photos SET faces_done = 1 WHERE id = ?", arrayOf(job.id))
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
