package com.reddol18.photo_tracer

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
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

        /** 스캔 진행 (화면·알림용). 한 번에 하나만 돈다 — 겹쳐 부르면 앞의 스캔이 끝난 뒤 새 사진만 본다 */
        @Volatile var phase: String? = null
        @Volatile var done = 0
        @Volatile var total = 0
        private val lock = Any()

        /** 구간당 대표 사진 수: 1장 → 1, 2~3 → 1, 4~7 → 2, 8~15 → 3 … 최대 5 */
        fun reps(n: Int): Int = if (n <= 1) 1 else minOf(5, 31 - Integer.numberOfLeadingZeros(n)) // ⌊log2 n⌋

        /** 구간(찍은 순서의 사진 id)에서 대표 사진: 시간상 고르게 reps(n)장 */
        fun chosen(ids: List<Long>): Set<Long> {
            val k = reps(ids.size)
            return (0 until k).map { j -> ids[((j + 0.5) * ids.size / k).toInt()] }.toSet()
        }

        /**
         * 구간 모양의 지문(#31): 구간마다 번호(순서)·사진 id·찍은 시각·대표 여부를 차례로 섞은 64비트 값(FNV-1a).
         * events는 구간마다 (사진 id, 찍은 시각)을 찍은 순서로. 다시 만들어도 지문이 같으면 화면이 볼 것(번호·장 수·표지·날짜)은 그대로다
         */
        fun signature(events: List<List<Pair<Long, Long>>>): Long {
            var h = -0x340d631b7bdddcdbL // FNV offset basis
            fun mix(v: Long) {
                var x = v
                for (b in 0 until 8) {
                    h = (h xor (x and 0xff)) * 0x100000001b3L
                    x = x ushr 8
                }
            }
            mix(events.size.toLong())
            events.forEachIndexed { i, e ->
                val rep = chosen(e.map { it.first })
                mix(i.toLong()); mix(e.size.toLong())
                for ((id, t) in e) { mix(id); mix(t); mix(if (id in rep) 1 else 0) }
            }
            return h
        }

        private fun segPrefs(ctx: Context) = ctx.getSharedPreferences("segments", Context.MODE_PRIVATE)

        /** 스캔이 구간을 바꾼 횟수(#31·#32). status에 실려 홈이 순간을 제자리에서 다시 읽는다 */
        fun segmentsGen(ctx: Context): Int = segPrefs(ctx).getInt("gen", 0)

        /** 새 구간의 지문이 지난번과 다를 때만 번호를 올린다. 바뀌었으면 true */
        private fun segmentsChanged(ctx: Context, sig: Long): Boolean {
            val p = segPrefs(ctx)
            if (p.contains("sig") && p.getLong("sig", 0) == sig) return false
            p.edit().putLong("sig", sig).putInt("gen", p.getInt("gen", 0) + 1).apply()
            return true
        }

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

        /** 저장소 루트 꼴: /storage/emulated/0/ (사용자 번호 아무거나), SD카드 /storage/XXXX-XXXX/ */
        private val STORAGE_ROOT = Regex("^/storage/(?:emulated/\\d+|[^/]+)/")

        /**
         * 28용: 절대 경로(DATA)를 RELATIVE_PATH 꼴('DCIM/Screenshots/')로 바꾼다 (#26).
         * RELATIVE_PATH(29)가 없어 DATA에서 만든다 — SCREEN_DIRS·Fake.kt의 startsWith 비교가 그대로 맞게 끝에 '/'를 붙인다.
         * root는 Environment.getExternalStorageDirectory() 경로(시험에서 안드로이드 없이 부르려고 밖에서 받는다).
         * 루트 바로 아래 파일은 ""(29의 RELATIVE_PATH도 그 자리는 빈 값과 같은 뜻), DATA가 없으면 null.
         */
        fun relPath(data: String?, root: String?): String? {
            if (data.isNullOrEmpty()) return null
            val r = root?.trimEnd('/')?.takeIf { it.isNotEmpty() }?.let { "$it/" }
            val rest = when {
                r != null && data.startsWith(r) -> data.substring(r.length)
                else -> STORAGE_ROOT.find(data)?.let { data.substring(it.range.last + 1) } ?: data.trimStart('/')
            }
            val slash = rest.lastIndexOf('/')
            return if (slash < 0) "" else rest.substring(0, slash + 1)
        }
    }

    private val db = Db.get(ctx)

    /** 반환: 바뀐 장 수(새로 넣은 장 + 갤러리에서 지워진 장). onProgress(읽은 장, 전체)는 100장마다 */
    fun scan(onProgress: (Int, Int) -> Unit = { _, _ -> }): Int = synchronized(lock) {
        try { phase = "읽기"; done = 0; total = 0; scanLocked(onProgress) } finally { phase = null }
    }

    private fun scanLocked(onProgress: (Int, Int) -> Unit): Int {
        val t0 = System.currentTimeMillis()
        val w = db.writableDatabase
        val known = HashSet<Long>()
        w.rawQuery("SELECT id FROM photos", null).use { while (it.moveToNext()) known.add(it.getLong(0)) }
        // RELATIVE_PATH는 29부터. 28은 DATA(절대 경로)를 읽어 같은 꼴로 바꾼다 (#26)
        val q = Build.VERSION.SDK_INT >= 29
        val root = if (q) null else Environment.getExternalStorageDirectory()?.absolutePath
        @Suppress("DEPRECATION")
        val cols = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME,
            if (q) MediaStore.Images.Media.RELATIVE_PATH else MediaStore.Images.Media.DATA, MediaStore.Images.Media.MIME_TYPE,
            MediaStore.Images.Media.DATE_MODIFIED, MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT)
        val seen = HashSet<Long>()
        var added = 0
        // 200장씩 한 트랜잭션으로 넣는다 (한 장씩 커밋하면 느리다). 중간에 멈추면 마지막 묶음만 다시 읽는다
        // 갤러리를 못 읽으면(권한 회수 등) 아무것도 지우지 않고 끝낸다
        val cursor = ctx.contentResolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cols, null, null, null) ?: return 0
        w.beginTransaction()
        try { cursor.use { c ->
            total = c.count
            while (c.moveToNext()) {
                val id = c.getLong(0)
                seen.add(id)
                done = seen.size
                if (done % 100 == 0) onProgress(done, total)
                if (id in known) continue
                val v = ContentValues()
                val name = c.getString(1) ?: ""
                val path = (if (q) c.getString(2) else relPath(c.getString(2), root)) ?: ""
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
                if (added % 200 == 0) {
                    w.setTransactionSuccessful(); w.endTransaction(); w.beginTransaction()
                    Log.i("PhotoTracer", "스캔: 새 사진 $added 장")
                }
            }
        }; w.setTransactionSuccessful() } finally { w.endTransaction() }
        onProgress(done, total)
        phase = "구간"
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
        return added + gone.size
    }

    private fun readExif(id: Long, v: ContentValues) {
        try {
            // 위치 정보는 원본을 요청해야 가려지지 않는다(ACCESS_MEDIA_LOCATION). 28은 가리기 자체가 없어 원래 URI 그대로 (#26)
            val base = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
            val uri = if (Build.VERSION.SDK_INT >= 29) MediaStore.setRequireOriginal(base) else base
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
                exif.latLong?.let { ll -> v.put("lat", ll[0]); v.put("lon", ll[1]) }
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
                val picked = chosen(e.map { it.id })
                for (s in e) {
                    w.execSQL("UPDATE photos SET segment = ?, is_rep = ? WHERE id = ?", arrayOf<Any>(i, if (s.id in picked) 1 else 0, s.id))
                }
                w.insert("segments", null, ContentValues().apply {
                    put("id", i); put("start", e.first().t); put("end", e.last().t); put("n", e.size)
                })
            }
            w.setTransactionSuccessful()
        } finally { w.endTransaction() }
        // 저장한 뒤에 번호를 올린다: 화면이 번호를 보고 읽을 때는 새 구간이 이미 들어가 있다(#31)
        val moved = segmentsChanged(ctx, signature(events.map { e -> e.map { it.id to it.t } }))
        Log.i("PhotoTracer", "구간 ${events.size}개 · 대표 사진 ${events.sumOf { reps(it.size) }}장 (구간 대상 ${shots.size}장)${if (moved) " · 바뀜" else ""}")
    }
}
