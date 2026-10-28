package com.reddol18.photo_tracer

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.provider.MediaStore
import android.util.Log
import android.util.Size
import java.io.File

/**
 * 등록한 인물. 사용자가 사람마다 '정답 얼굴'을 몇 개 고르면, 나머지 얼굴은 정답 얼굴과의 최대 코사인 유사도로 찾는다.
 * 0단계 evaluate.py(사람이 붙인 정답 370얼굴): 연도마다 3개씩 등록 + 기준 0.45 + 1·2등 차이 0.10 →
 *   정밀도 99.1%, 재현율 82.6%, 등록 안 한 사람(남의 아이)을 가족으로 잘못 붙이는 비율 6.0%.
 *   자동 묶음(People)은 아이들끼리 섞여 중심이 흐려지므로 고를 때 참고로만 쓴다.
 * '이 사람 아님'으로 표시한 얼굴은 그 인물의 반례가 되어, 반례와 더 닮은 얼굴은 그 인물로 붙이지 않는다(차이 기준도 같이 본다).
 * 기준에 못 미치지만 가까운 얼굴(0.35 이상, 또는 차이가 모자람)은 maybe로 두어 사용자가 확인하게 한다.
 * 한 사진에서 한 인물은 얼굴 하나에만 붙인다(찾음 > 확인 필요 > 유사도 순). 실사 아닌 이미지(Fake) 속 얼굴은 추측하지 않는다.
 */
class Who(private val ctx: Context) {
    companion object {
        const val THRESHOLD = 0.45f
        const val MARGIN = 0.10f
        const val MAYBE = 0.35f
        const val NOBODY = -1L // face_marks.person: '아무도 아님'으로 뺀 얼굴
        const val RULE = 6 // 붙이는 규칙이 바뀌면 올린다 → 앱을 열 때 한 번 다시 붙인다 (2: 사진당 한 얼굴, 캡처 제외, 3·4: 실사 아닌 이미지 제외)
        const val FACE_MAX = 2048 // 얼굴 조각을 자를 때 사진을 읽는 최대 크기
        private const val COVER_CANDS = 5 // 대표 얼굴: 크게 담기는 정답 얼굴 몇 개 중에서 선명도로 고른다

        // 얼굴 썸네일에 실제로 담기는 픽셀 수: 얼굴 면적 × 사진 면적, 단 FACE_MAX보다 크게는 읽지 않는다
        private val CROP_PX = "f.w * f.h * MIN(ph.w * ph.h, $FACE_MAX.0 * $FACE_MAX * ph.w * ph.h / (MAX(ph.w, ph.h) * MAX(ph.w, ph.h)))"
    }

    private val db = Db.get(ctx)

    fun people(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        db.readableDatabase.rawQuery("""SELECT p.id, p.name, p.relation, p.birth_year,
                (SELECT COUNT(DISTINCT photo_id) FROM faces WHERE who = p.id),
                (SELECT COUNT(*) FROM face_marks WHERE person = p.id AND ok = 1)
                FROM people p ORDER BY p.id""", null).use {
            while (it.moveToNext()) out.add(mapOf("id" to it.getLong(0), "name" to it.getString(1), "relation" to it.getString(2),
                "birth_year" to (if (it.isNull(3)) null else it.getInt(3)), "n" to it.getInt(4),
                "refs" to it.getInt(5), "face" to cover(it.getLong(0))))
        }
        return out
    }

    /** 대표 얼굴: 정답 얼굴 중 크게 담기는 몇 개를 고르고(실사 아닌 이미지는 뒤로), 그중 가장 선명한 것.
     *  크기만 보면 흔들린 사진이 뽑힌다. 선명도는 한 번 재면 faces.sharp에 둔다 */
    private fun cover(person: Long): Long? {
        val cands = ArrayList<Pair<Long, Double?>>()
        db.readableDatabase.rawQuery("""SELECT f.id, f.sharp FROM face_marks m JOIN faces f ON f.id = m.face_id JOIN photos ph ON ph.id = f.photo_id
                WHERE m.person = ? AND m.ok = 1 ORDER BY COALESCE(ph.fake, 0) > 0, $CROP_PX DESC LIMIT $COVER_CANDS""",
            arrayOf(person.toString())).use { while (it.moveToNext()) cands.add(it.getLong(0) to (if (it.isNull(1)) null else it.getDouble(1))) }
        val t = System.currentTimeMillis()
        var measured = 0
        return cands.maxByOrNull { (id, s) ->
            s ?: sharpness(id).also { v -> measured++; db.writableDatabase.execSQL("UPDATE faces SET sharp = ? WHERE id = ?", arrayOf<Any>(v, id)) }
        }?.first.also { if (measured > 0) Log.i("Who", "대표 얼굴 $person: 선명도 ${measured}개 ${System.currentTimeMillis() - t}ms") }
    }

    /** 얼굴 조각(여백 30%)을 사진에서 잘라 out×out으로. 작은 얼굴은 사진을 크게 읽는다(최대 FACE_MAX) */
    fun faceBitmap(faceId: Long, out: Int): Bitmap? {
        val f = db.readableDatabase.rawQuery("SELECT photo_id, x, y, w, h FROM faces WHERE id = ?", arrayOf(faceId.toString())).use {
            if (!it.moveToFirst()) return null
            listOf(it.getDouble(0), it.getDouble(1), it.getDouble(2), it.getDouble(3), it.getDouble(4))
        }
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, f[0].toLong())
        // 768로 읽으면 작은 얼굴은 잘라낸 조각이 몇십 픽셀뿐이라 흐리다 → 얼굴 조각이 200픽셀쯤 되게 읽는다
        val side = (200 / (maxOf(f[3], f[4]) * 1.3)).toInt().coerceIn(768, FACE_MAX)
        val bmp = ctx.contentResolver.loadThumbnail(uri, Size(side, side), null)
        val cx = (f[1] + f[3] / 2) * bmp.width; val cy = (f[2] + f[4] / 2) * bmp.height
        val half = maxOf(f[3] * bmp.width, f[4] * bmp.height) * 0.65
        val r = Rect((cx - half).toInt().coerceAtLeast(0), (cy - half).toInt().coerceAtLeast(0),
                     (cx + half).toInt().coerceAtMost(bmp.width), (cy + half).toInt().coerceAtMost(bmp.height))
        if (r.width() < 2 || r.height() < 2) return Bitmap.createScaledBitmap(bmp, out, out, true)
        val crop = Bitmap.createBitmap(bmp, r.left, r.top, r.width(), r.height())
        bmp.recycle()
        return Bitmap.createScaledBitmap(crop, out, out, true).also { if (it !== crop) crop.recycle() }
    }

    /** 선명도: 128×128 회색 얼굴 조각의 라플라시안 분산. 흔들리거나 작은 얼굴을 늘린 조각은 낮다 */
    private fun sharpness(faceId: Long): Double {
        val bmp = try { faceBitmap(faceId, 128) } catch (e: Exception) { Log.w("Who", "선명도 실패 $faceId: $e"); null } ?: return 0.0
        val n = 128
        val px = IntArray(n * n).also { bmp.getPixels(it, 0, n, 0, 0, n, n) }
        bmp.recycle()
        val g = DoubleArray(px.size) { val c = px[it]; 0.299 * (c shr 16 and 255) + 0.587 * (c shr 8 and 255) + 0.114 * (c and 255) }
        var sum = 0.0; var sq = 0.0; var k = 0
        for (y in 1 until n - 1) for (x in 1 until n - 1) {
            val i = y * n + x
            val l = g[i - 1] + g[i + 1] + g[i - n] + g[i + n] - 4 * g[i]
            sum += l; sq += l * l; k++
        }
        return sq / k - (sum / k) * (sum / k)
    }

    private fun info(name: String, relation: String?, birthYear: Int?) = ContentValues().apply {
        put("name", name); put("relation", relation?.ifBlank { null }); put("birth_year", birthYear)
    }

    /** 새 인물: 고른 얼굴들을 정답으로. relation(관계)·birthYear(생년)는 비워도 된다 */
    fun create(name: String, relation: String?, birthYear: Int?, faces: List<Long>): Long {
        val id = db.writableDatabase.insert("people", null, info(name, relation, birthYear))
        mark(id, faces, true)
        return id
    }

    fun update(id: Long, name: String, relation: String?, birthYear: Int?) {
        db.writableDatabase.update("people", info(name, relation, birthYear), "id = ?", arrayOf(id.toString()))
    }

    fun delete(id: Long) {
        val w = db.writableDatabase
        w.execSQL("DELETE FROM face_marks WHERE person = ?", arrayOf(id))
        w.execSQL("DELETE FROM people WHERE id = ?", arrayOf(id))
        assignAll()
    }

    /**
     * ok=true: 정답 얼굴로, false: 이 사람 아님. 같은 얼굴의 예전 표시는 덮어쓴다.
     * '아님'은 그 얼굴을 아무에게도 붙이지 않는다(NOBODY 표시) — 그러지 않으면 2등 인물(예: 딸 친구)로 넘어가 버린다.
     * 이 인물의 반례로도 남겨 비슷한 다른 얼굴을 덜 붙이게 한다. 나중에 누군가의 정답으로 고르면 NOBODY는 풀린다.
     */
    fun mark(person: Long, faces: List<Long>, ok: Boolean) {
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            for (f in faces) put(f, person, ok)
            w.setTransactionSuccessful()
        } finally { w.endTransaction() }
        assignAll()
    }

    private fun put(face: Long, person: Long, ok: Boolean) {
        val w = db.writableDatabase
        w.execSQL("INSERT OR REPLACE INTO face_marks(face_id, person, ok) VALUES (?, ?, ?)", arrayOf<Any>(face, person, if (ok) 1 else 0))
        // 한 얼굴은 한 사람의 정답만 될 수 있다
        if (ok) w.execSQL("DELETE FROM face_marks WHERE face_id = ? AND (person = ? OR (person != ? AND ok = 1))", arrayOf<Any>(face, NOBODY, person))
        else w.execSQL("INSERT OR REPLACE INTO face_marks(face_id, person, ok) VALUES (?, ?, 0)", arrayOf<Any>(face, NOBODY))
    }

    /** 사진 한 장에서 추측으로 붙은 이름(찾음·확인 필요)을 모두 '아님'으로. 정답 얼굴은 그대로 둔다 */
    fun rejectAll(photo: Long) {
        val hits = ArrayList<Pair<Long, Long>>()
        db.readableDatabase.rawQuery("""SELECT f.id, COALESCE(f.who, f.maybe) FROM faces f
                WHERE f.photo_id = ? AND COALESCE(f.who, f.maybe) IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM face_marks m WHERE m.face_id = f.id AND m.ok = 1)""",
            arrayOf(photo.toString())).use { while (it.moveToNext()) hits.add(it.getLong(0) to it.getLong(1)) }
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            for ((face, person) in hits) put(face, person, false)
            w.setTransactionSuccessful()
        } finally { w.endTransaction() }
        assignAll()
    }

    /** 사진 단위로 '이 사람 아님': 그 사진에서 이 인물로 붙은(또는 애매한) 얼굴을 반례로 */
    fun rejectPhotos(person: Long, photos: List<Long>) {
        val faces = ArrayList<Long>()
        for (p in photos) db.readableDatabase.rawQuery("SELECT id FROM faces WHERE photo_id = ? AND (who = ? OR maybe = ?)",
            arrayOf(p.toString(), person.toString(), person.toString())).use { while (it.moveToNext()) faces.add(it.getLong(0)) }
        mark(person, faces, false)
    }

    /** 사진 단위로 정답: 그 사진에서 이 인물로 붙은(또는 애매한) 얼굴 중 가장 닮은 것 */
    fun confirmPhotos(person: Long, photos: List<Long>) {
        val faces = ArrayList<Long>()
        for (p in photos) db.readableDatabase.rawQuery(
            "SELECT id FROM faces WHERE photo_id = ? AND (who = ? OR maybe = ?) ORDER BY who_sim DESC LIMIT 1",
            arrayOf(p.toString(), person.toString(), person.toString())).use { if (it.moveToFirst()) faces.add(it.getLong(0)) }
        mark(person, faces, true)
    }

    /** 합치기: 정답·반례를 첫 번째 인물로 모으고 나머지는 지운다 */
    fun merge(ids: List<Long>) {
        if (ids.size < 2) return
        val into = ids[0]
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            for (p in ids.drop(1)) {
                w.execSQL("INSERT OR REPLACE INTO face_marks(face_id, person, ok) SELECT face_id, ?, ok FROM face_marks WHERE person = ?", arrayOf<Any>(into, p))
                w.execSQL("DELETE FROM face_marks WHERE person = ?", arrayOf<Any>(p))
                w.execSQL("DELETE FROM people WHERE id = ?", arrayOf<Any>(p))
            }
            w.setTransactionSuccessful()
        } finally { w.endTransaction() }
        assignAll()
    }

    /**
     * 인물의 사진. kind: ref(정답), found(찾음), maybe(확인 필요). sim: 그 사진 속 이 인물 얼굴의 정답 얼굴과 최대 유사도.
     * face: 그 얼굴(사진 위에 초록 상자로 그린다). taken: 찍은 날(ms, 모르면 null — 연도 거르기용). 찍은 날 최근 순.
     */
    fun photos(person: Long): List<Map<String, Any?>> {
        val out = LinkedHashMap<Long, Map<String, Any?>>()
        db.readableDatabase.rawQuery("""
            SELECT f.photo_id, f.id, f.who_sim,
                   CASE WHEN m.ok = 1 THEN 'ref' WHEN f.who = ?1 THEN 'found' ELSE 'maybe' END, p.taken_at
            FROM faces f JOIN photos p ON p.id = f.photo_id
            LEFT JOIN face_marks m ON m.face_id = f.id AND m.person = ?1
            WHERE (f.who = ?1 OR f.maybe = ?1 OR m.ok = 1) AND COALESCE(m.ok, 1) = 1
            ORDER BY COALESCE(p.taken_at, p.received_at, 0) DESC, (m.ok = 1) DESC, f.who_sim DESC""",
            arrayOf(person.toString())).use {
            while (it.moveToNext()) {
                val photo = it.getLong(0)
                if (photo in out) continue // 한 사진에 둘이면 정답·높은 쪽
                out[photo] = mapOf("id" to photo, "face" to it.getLong(1), "sim" to (if (it.isNull(2)) 1.0 else it.getDouble(2)),
                    "kind" to it.getString(3), "taken" to (if (it.isNull(4)) null else it.getLong(4)))
            }
        }
        return out.values.toList()
    }

    /** 모든 얼굴을 정답·반례에 맞춰 다시 붙인다. 얼굴 1만 개 × 정답 수십 개라 1초 안쪽 */
    fun assignAll() {
        val t0 = System.currentTimeMillis()
        Fake(ctx).judgeNew()
        val pos = HashMap<Long, ArrayList<FloatArray>>()
        val neg = HashMap<Long, ArrayList<FloatArray>>()
        val marks = HashMap<Long, HashMap<Long, Boolean>>() // 얼굴 → 인물 → ok
        db.readableDatabase.rawQuery("SELECT m.face_id, m.person, m.ok, f.v FROM face_marks m JOIN faces f ON f.id = m.face_id", null).use {
            while (it.moveToNext()) {
                val ok = it.getInt(2) == 1
                (if (ok) pos else neg).getOrPut(it.getLong(1)) { ArrayList() }.add(Db.floats(it.getBlob(3)))
                marks.getOrPut(it.getLong(0)) { HashMap() }[it.getLong(1)] = ok
            }
        }
        val people = pos.keys.toList()
        class F(val id: Long, val photo: Long, val capture: Boolean, val v: FloatArray)
        val faces = ArrayList<F>()
        if (people.isNotEmpty()) db.readableDatabase.rawQuery(
            "SELECT f.id, f.photo_id, COALESCE(p.fake, 0) > 0, f.v FROM faces f JOIN photos p ON p.id = f.photo_id", null).use {
            while (it.moveToNext()) faces.add(F(it.getLong(0), it.getLong(1), it.getInt(2) == 1, Db.floats(it.getBlob(3))))
        }
        // 추측: 사진·인물마다 하나만 남긴다 (같은 사진에 같은 사람이 둘일 수 없다. 그 사진에 정답 얼굴이 있으면 추측은 없다)
        class Hit(val face: Long, val person: Long, val sim: Float, val found: Boolean)
        val hits = HashMap<Pair<Long, Long>, Hit>() // (사진, 인물) → 가장 나은 추측
        val refIn = HashSet<Pair<Long, Long>>()
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            w.execSQL("UPDATE faces SET who = NULL, who_sim = NULL, maybe = NULL")
            for (f in faces) {
                val id = f.id; val v = f.v
                val m = marks[id]
                val ref = m?.entries?.firstOrNull { it.value }?.key
                if (ref != null) {
                    w.execSQL("UPDATE faces SET who = ?, who_sim = 1 WHERE id = ?", arrayOf<Any>(ref, id))
                    refIn.add(f.photo to ref)
                    continue
                }
                if (m?.containsKey(NOBODY) == true) continue // 사용자가 '아님'으로 뺀 얼굴
                if (f.capture) continue // 화면 캡처·만든 이미지(AI 아바타·연예인 사진) 속 얼굴은 추측하지 않는다 (Fake.kt)
                // 인물마다 정답 얼굴과의 최대 유사도. 반례로 표시한 인물은 뺀다
                val sims = people.filter { p -> m?.get(p) != false }.map { p -> p to pos[p]!!.maxOf { r -> dot(v, r) } }
                    .sortedByDescending { it.second }
                if (sims.isEmpty()) continue
                val (best, s) = sims[0]
                // 2등: 다른 인물, 또는 이 인물의 반례(이 인물이 아니라고 한 얼굴과 더 닮았나)
                val second = maxOf(sims.getOrNull(1)?.second ?: -1f, neg[best]?.maxOf { r -> dot(v, r) } ?: -1f)
                val hit = when {
                    s >= THRESHOLD && s - second >= MARGIN -> Hit(id, best, s, true)
                    s >= MAYBE && s > second -> Hit(id, best, s, false)
                    else -> null
                } ?: continue
                val key = f.photo to best
                val cur = hits[key]
                if (cur == null || (hit.found && !cur.found) || (hit.found == cur.found && hit.sim > cur.sim)) hits[key] = hit
            }
            for ((key, h) in hits) {
                if (key in refIn) continue
                w.execSQL("UPDATE faces SET ${if (h.found) "who" else "maybe"} = ?, who_sim = ? WHERE id = ?", arrayOf<Any>(h.person, h.sim, h.face))
            }
            w.setTransactionSuccessful()
        } finally { w.endTransaction() }
        Log.i("PhotoTracer", "인물 ${people.size}명 다시 붙임, ${System.currentTimeMillis() - t0}ms")
        try { exportFound() } catch (e: Exception) { Log.w("PhotoTracer", "who_found.csv 실패: $e") }
    }

    /**
     * 점검용: '찾음' 얼굴마다 가장 닮은 정답 얼굴과 사진 출처·실사 판정을 앱 폴더 who_found.csv로(이름·사진은 안 쓴다, 인물은 번호).
     * 연예인·AI 그림이 왜 붙었나(판정을 빠져나갔나, 어느 정답과 닮았나)를 PC에서 썸네일과 맞춰 본다(poc/who_found.py).
     */
    private fun exportFound() {
        val dir = ctx.getExternalFilesDir(null) ?: return
        val refs = HashMap<Long, ArrayList<Triple<Long, Long, FloatArray>>>() // 인물 → (정답 얼굴, 사진, 벡터)
        db.readableDatabase.rawQuery("""SELECT m.person, f.id, f.photo_id, f.v FROM face_marks m JOIN faces f ON f.id = m.face_id
                WHERE m.ok = 1""", null).use {
            while (it.moveToNext()) refs.getOrPut(it.getLong(0)) { ArrayList() }.add(Triple(it.getLong(1), it.getLong(2), Db.floats(it.getBlob(3))))
        }
        // 정답 얼굴마다: 다른 인물의 정답 얼굴과 가장 닮은 정도. 가리거나 작은 얼굴은 벡터가 흐려 아무 얼굴과도 닮는다
        File(dir, "who_refs.csv").bufferedWriter().use { out ->
            out.write("ref_face,photo,person,other_max,other_person,other_face\n")
            for ((p, rs) in refs) for ((face, photo, v) in rs) {
                var best = -2f; var bp = 0L; var bf = 0L
                for ((q, qs) in refs) if (q != p) for ((qf, _, qv) in qs) { val s = dot(v, qv); if (s > best) { best = s; bp = q; bf = qf } }
                out.write("$face,$photo,$p,$best,$bp,$bf\n")
            }
        }
        // 정답 얼굴끼리: 같은 사람 / 다른 사람 유사도 분포 (PC 0단계: 같은 사람 중앙값 0.52, 다른 사람 0.13, 95% 0.40)
        val same = ArrayList<Float>(); val diff = ArrayList<Float>(); val diffSamePhoto = ArrayList<Float>()
        val all = refs.flatMap { (p, rs) -> rs.map { p to it } }
        for (i in all.indices) for (j in i + 1 until all.size) {
            val s = dot(all[i].second.third, all[j].second.third)
            when {
                all[i].first == all[j].first -> same.add(s)
                all[i].second.second == all[j].second.second -> diffSamePhoto.add(s)
                else -> diff.add(s)
            }
        }
        val q = { l: List<Float>, f: Double -> l.sorted().let { if (it.isEmpty()) Float.NaN else it[((it.size - 1) * f).toInt()] } }
        Log.i("PhotoTracer", "정답 얼굴 유사도: 같은 사람 ${same.size}쌍 중앙 ${q(same, .5)} / 다른 사람 ${diff.size}쌍 중앙 ${q(diff, .5)} 95% ${q(diff, .95)}" +
            " / 같은 사진 다른 사람 ${diffSamePhoto.size}쌍 중앙 ${q(diffSamePhoto, .5)}")
        File(dir, "who_found.csv").bufferedWriter().use { out ->
            out.write("face,photo,person,sim,ref_face,ref_photo,date_source,mime,dir,vec,fake,cap,pscore,x,y,w,h\n")
            db.readableDatabase.rawQuery("""SELECT f.id, f.photo_id, f.who, f.who_sim, f.v, p.date_source, p.mime, p.path,
                    v.photo_id IS NOT NULL, p.fake, p.fake_cap, p.fake_person, f.x, f.y, f.w, f.h
                    FROM faces f JOIN photos p ON p.id = f.photo_id LEFT JOIN vectors v ON v.photo_id = p.id
                    WHERE f.who IS NOT NULL AND f.id NOT IN (SELECT face_id FROM face_marks WHERE ok = 1)""", null).use {
                val s = { i: Int -> if (it.isNull(i)) "" else it.getString(i) }
                while (it.moveToNext()) {
                    val v = Db.floats(it.getBlob(4))
                    val ref = refs[it.getLong(2)]?.maxByOrNull { r -> dot(v, r.third) }
                    val folder = s(7).substringBeforeLast('/', "").replace(",", " ")
                    out.write(listOf(s(0), s(1), s(2), s(3), ref?.first ?: "", ref?.second ?: "", s(5), s(6), folder, s(8), s(9), s(10), s(11),
                        s(12), s(13), s(14), s(15)).joinToString(",") + "\n")
                }
            }
        }
    }

    private fun dot(a: FloatArray, b: FloatArray): Float { var s = 0f; for (d in a.indices) s += a[d] * b[d]; return s }
}
