package com.reddol18.photo_tracer

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.media.ExifInterface
import android.provider.MediaStore
import android.util.Log
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 갤러리를 DB와 맞춘다: 새 사진만 EXIF를 읽어 넣고, 지운 사진은 결과까지 지운다. 그다음 구간과 대표 사진을 다시 정한다.
 * 날짜 규칙 (0단계 time_events.py · undated_dates.py):
 *   EXIF 촬영 시각 + 제조사 → '카메라', 제조사 없음 → '기타 EXIF', 스크린샷 폴더·PNG → '화면 캡처'
 *   EXIF 없음 → 파일 이름의 날짜면 '이름'(추정), 아니면 '없음'
 *   받은 날 = 파일 저장 시각. 하루에 50장 이상 저장된 날(폰 옮기기·대량 복사)은 비운다
 * 구간: 찍은 날을 아는 '카메라'·'기타 EXIF' 사진만. 3시간 넘는 공백이나 마지막 GPS 위치에서 1km 넘는 이동이면 자른다.
 * 대표 사진: 구간 크기에 따라 1~5장, 시간상 고르게 (중복·흐림 교체는 아직 안 함).
 */
class Scanner(private val ctx: Context) {
    companion object {
        const val GAP_MS = 3 * 3600_000L
        const val MOVE_KM = 1.0
        const val MASS_MOVE = 50
        private val SCREEN_DIRS = listOf("DCIM/Screenshots", "DCIM/Videocaptures")
        private val EXIF_FMT = DateTimeFormatter.ofPattern("yyyy:MM:dd HH:mm:ss")
        private val NAME_DT = Regex("((?:19|20)\\d{2})(\\d{2})(\\d{2})[_-](\\d{2})(\\d{2})(\\d{2})")
        private val NAME_D = Regex("((?:19|20)\\d{2})-(\\d{2})-(\\d{2})")
        private val NAME_MS = Regex("(?<!\\d)(1[3-7]\\d{11})(?!\\d)")

        /** 구간당 대표 사진 수: 1장 → 1, 2~3 → 1, 4~7 → 2, 8~15 → 3 … 최대 5 */
        fun reps(n: Int): Int = if (n <= 1) 1 else minOf(5, 31 - Integer.numberOfLeadingZeros(n)) // ⌊log2 n⌋

        fun km(a: DoubleArray, b: DoubleArray): Double {
            val r = Math.PI / 180
            val h = sin((b[0] - a[0]) * r / 2).let { it * it } +
                cos(a[0] * r) * cos(b[0] * r) * sin((b[1] - a[1]) * r / 2).let { it * it }
            return 6371 * 2 * asin(sqrt(h))
        }

        fun nameDate(name: String): Long? {
            NAME_DT.find(name)?.let { m ->
                val g = m.groupValues.drop(1).map { it.toInt() }
                return runCatching { LocalDateTime.of(g[0], g[1], g[2], g[3], g[4], g[5]).toMs() }.getOrNull()
            }
            NAME_D.find(name)?.let { m ->
                val g = m.groupValues.drop(1).map { it.toInt() }
                return runCatching { LocalDate.of(g[0], g[1], g[2]).atTime(12, 0).toMs() }.getOrNull()
            }
            return NAME_MS.find(name)?.groupValues?.get(1)?.toLong()
        }

        private fun LocalDateTime.toMs(): Long = atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
    }

    private val db = Db.get(ctx)

    /** 반환: 새로 넣은 장 수 */
    fun scan(): Int {
        val t0 = System.currentTimeMillis()
        val w = db.writableDatabase
        val known = HashSet<Long>()
        w.rawQuery("SELECT id FROM photos", null).use { while (it.moveToNext()) known.add(it.getLong(0)) }
        val cols = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH, MediaStore.Images.Media.MIME_TYPE,
            MediaStore.Images.Media.DATE_MODIFIED, MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT)
        val seen = HashSet<Long>()
        var added = 0
        ctx.contentResolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cols, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                seen.add(id)
                if (id in known) continue
                val v = ContentValues()
                val name = c.getString(1) ?: ""
                val path = c.getString(2) ?: ""
                val mime = c.getString(3) ?: ""
                v.put("id", id); v.put("name", name); v.put("path", path); v.put("mime", mime)
                v.put("w", c.getInt(5)); v.put("h", c.getInt(6))
                v.put("received_at", c.getLong(4) * 1000)
                readExif(id, v)
                val taken = v.getAsLong("taken_at")
                val source = when {
                    taken == null -> nameDate(name)?.let { v.put("taken_at", it); "이름" } ?: "없음"
                    SCREEN_DIRS.any { path.startsWith(it) } || (v.getAsString("make") == null && mime == "image/png") -> "화면 캡처"
                    v.getAsString("make") != null -> "카메라"
                    else -> "기타 EXIF"
                }
                v.remove("make")
                v.put("date_source", source)
                w.insertWithOnConflict("photos", null, v, SQLiteDatabase.CONFLICT_REPLACE)
                added++
                if (added % 500 == 0) Log.i("PhotoTracer", "스캔: 새 사진 $added 장")
            }
        }
        val gone = known - seen
        if (gone.isNotEmpty()) {
            w.beginTransaction()
            try {
                for (id in gone) {
                    val a = arrayOf(id.toString())
                    w.delete("photos", "id = ?", a); w.delete("vectors", "photo_id = ?", a); w.delete("faces", "photo_id = ?", a)
                }
                w.setTransactionSuccessful()
            } finally { w.endTransaction() }
        }
        if (added > 0 || gone.isNotEmpty()) {
            massMoveDays()
            segment()
        }
        Log.i("PhotoTracer", "스캔 끝: 새 사진 $added, 지운 사진 ${gone.size}, ${System.currentTimeMillis() - t0}ms")
        return added
    }

    private fun readExif(id: Long, v: ContentValues) {
        try {
            // 위치 정보는 원본을 요청해야 가려지지 않는다(ACCESS_MEDIA_LOCATION)
            val uri = MediaStore.setRequireOriginal(ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id))
            ctx.contentResolver.openInputStream(uri)?.use { s ->
                val exif = ExifInterface(s)
                exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)?.trim()?.take(19)?.let { dt ->
                    runCatching {
                        val local = LocalDateTime.parse(dt, EXIF_FMT)
                        val tz = exif.getAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL)
                        val ms = tz?.let { runCatching { local.atOffset(ZoneOffset.of(it)).toInstant().toEpochMilli() }.getOrNull() }
                        v.put("taken_at", ms ?: local.toMs())
                    }
                }
                exif.getAttribute(ExifInterface.TAG_MAKE)?.let { v.put("make", it) }
                val ll = FloatArray(2)
                if (exif.getLatLong(ll)) { v.put("lat", ll[0].toDouble()); v.put("lon", ll[1].toDouble()) }
            }
        } catch (e: Exception) {
            // 읽을 수 없는 파일: 날짜 없음으로 둔다
        }
    }

    /** 찍은 날이 없는 사진들 중 하루에 MASS_MOVE장 이상 저장된 날은 받은 날을 비운다 */
    private fun massMoveDays() {
        val w = db.writableDatabase
        val days = HashMap<Long, MutableList<Long>>()
        w.rawQuery("SELECT id, received_at FROM photos WHERE date_source IN ('없음', '이름') AND received_at IS NOT NULL", null).use {
            while (it.moveToNext()) {
                val day = java.time.Instant.ofEpochMilli(it.getLong(1)).atZone(ZoneId.systemDefault()).toLocalDate().toEpochDay()
                days.getOrPut(day) { ArrayList() }.add(it.getLong(0))
            }
        }
        w.beginTransaction()
        try {
            days.values.filter { it.size >= MASS_MOVE }.flatten().forEach {
                w.execSQL("UPDATE photos SET received_at = NULL WHERE id = ?", arrayOf(it))
            }
            w.setTransactionSuccessful()
        } finally { w.endTransaction() }
    }

    private class Shot(val id: Long, val t: Long, val ll: DoubleArray?)

    private fun segment() {
        val w = db.writableDatabase
        val shots = ArrayList<Shot>()
        w.rawQuery("""SELECT id, taken_at, lat, lon FROM photos WHERE date_source IN ('카메라', '기타 EXIF')
                      ORDER BY taken_at, id""", null).use {
            while (it.moveToNext()) {
                shots.add(Shot(it.getLong(0), it.getLong(1),
                    if (it.isNull(2)) null else doubleArrayOf(it.getDouble(2), it.getDouble(3))))
            }
        }
        val events = ArrayList<List<Shot>>()
        var cur = ArrayList<Shot>()
        var last: DoubleArray? = null
        for (s in shots) {
            val prev = cur.lastOrNull()
            val far = last != null && s.ll != null && km(last, s.ll) > MOVE_KM
            if (prev != null && (s.t - prev.t > GAP_MS || far)) {
                events.add(cur); cur = ArrayList(); last = null
            }
            cur.add(s)
            if (s.ll != null) last = s.ll
        }
        if (cur.isNotEmpty()) events.add(cur)

        w.beginTransaction()
        try {
            w.execSQL("UPDATE photos SET segment = NULL, is_rep = 0")
            w.delete("segments", null, null)
            events.forEachIndexed { i, e ->
                val k = reps(e.size)
                val chosen = (0 until k).map { j -> e[((j + 0.5) * e.size / k).toInt()].id }.toSet()
                for (s in e) {
                    w.execSQL("UPDATE photos SET segment = ?, is_rep = ? WHERE id = ?", arrayOf<Any>(i, if (s.id in chosen) 1 else 0, s.id))
                }
                w.insert("segments", null, ContentValues().apply {
                    put("id", i); put("start", e.first().t); put("end", e.last().t); put("n", e.size)
                })
            }
            w.setTransactionSuccessful()
        } finally { w.endTransaction() }
        Log.i("PhotoTracer", "구간 ${events.size}개 · 대표 사진 ${events.sumOf { reps(it.size) }}장 (구간 대상 ${shots.size}장)")
    }
}
