package com.reddol18.photo_tracer

import android.content.ContentValues
import android.content.Context
import android.util.Log

/**
 * 등록한 인물. 사용자가 사람마다 '정답 얼굴'을 몇 개 고르면, 나머지 얼굴은 정답 얼굴과의 최대 코사인 유사도로 찾는다.
 * 0단계 evaluate.py(사람이 붙인 정답 370얼굴): 연도마다 3개씩 등록 + 기준 0.45 + 1·2등 차이 0.10 →
 *   정밀도 99.1%, 재현율 82.6%, 등록 안 한 사람(남의 아이)을 가족으로 잘못 붙이는 비율 6.0%.
 *   자동 묶음(People)은 아이들끼리 섞여 중심이 흐려지므로 고를 때 참고로만 쓴다.
 * '이 사람 아님'으로 표시한 얼굴은 그 인물의 반례가 되어, 반례와 더 닮은 얼굴은 그 인물로 붙이지 않는다(차이 기준도 같이 본다).
 * 기준에 못 미치지만 가까운 얼굴(0.35 이상, 또는 차이가 모자람)은 maybe로 두어 사용자가 확인하게 한다.
 */
class Who(ctx: Context) {
    companion object {
        const val THRESHOLD = 0.45f
        const val MARGIN = 0.10f
        const val MAYBE = 0.35f
        const val NOBODY = -1L // face_marks.person: '아무도 아님'으로 뺀 얼굴
    }

    private val db = Db.get(ctx)

    fun people(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        db.readableDatabase.rawQuery("""SELECT p.id, p.name, p.relation, p.birth_year,
                (SELECT COUNT(DISTINCT photo_id) FROM faces WHERE who = p.id),
                (SELECT COUNT(*) FROM face_marks WHERE person = p.id AND ok = 1),
                (SELECT face_id FROM face_marks WHERE person = p.id AND ok = 1 LIMIT 1)
                FROM people p ORDER BY p.id""", null).use {
            while (it.moveToNext()) out.add(mapOf("id" to it.getLong(0), "name" to it.getString(1), "relation" to it.getString(2),
                "birth_year" to (if (it.isNull(3)) null else it.getInt(3)), "n" to it.getInt(4),
                "refs" to it.getInt(5), "face" to (if (it.isNull(6)) null else it.getLong(6))))
        }
        return out
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
            for (f in faces) {
                w.execSQL("INSERT OR REPLACE INTO face_marks(face_id, person, ok) VALUES (?, ?, ?)", arrayOf<Any>(f, person, if (ok) 1 else 0))
                // 한 얼굴은 한 사람의 정답만 될 수 있다
                if (ok) w.execSQL("DELETE FROM face_marks WHERE face_id = ? AND (person = ? OR (person != ? AND ok = 1))", arrayOf<Any>(f, NOBODY, person))
                else w.execSQL("INSERT OR REPLACE INTO face_marks(face_id, person, ok) VALUES (?, ?, 0)", arrayOf<Any>(f, NOBODY))
            }
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
        val faces = ArrayList<Pair<Long, FloatArray>>()
        if (people.isNotEmpty()) db.readableDatabase.rawQuery("SELECT id, v FROM faces", null).use {
            while (it.moveToNext()) faces.add(it.getLong(0) to Db.floats(it.getBlob(1)))
        }
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            w.execSQL("UPDATE faces SET who = NULL, who_sim = NULL, maybe = NULL")
            for ((id, v) in faces) {
                val m = marks[id]
                val ref = m?.entries?.firstOrNull { it.value }?.key
                if (ref != null) {
                    w.execSQL("UPDATE faces SET who = ?, who_sim = 1 WHERE id = ?", arrayOf<Any>(ref, id))
                    continue
                }
                if (m?.containsKey(NOBODY) == true) continue // 사용자가 '아님'으로 뺀 얼굴
                // 인물마다 정답 얼굴과의 최대 유사도. 반례로 표시한 인물은 뺀다
                val sims = people.filter { p -> m?.get(p) != false }.map { p -> p to pos[p]!!.maxOf { r -> dot(v, r) } }
                    .sortedByDescending { it.second }
                if (sims.isEmpty()) continue
                val (best, s) = sims[0]
                // 2등: 다른 인물, 또는 이 인물의 반례(이 인물이 아니라고 한 얼굴과 더 닮았나)
                val second = maxOf(sims.getOrNull(1)?.second ?: -1f, neg[best]?.maxOf { r -> dot(v, r) } ?: -1f)
                when {
                    s >= THRESHOLD && s - second >= MARGIN ->
                        w.execSQL("UPDATE faces SET who = ?, who_sim = ? WHERE id = ?", arrayOf<Any>(best, s, id))
                    s >= MAYBE && s > second ->
                        w.execSQL("UPDATE faces SET maybe = ?, who_sim = ? WHERE id = ?", arrayOf<Any>(best, s, id))
                }
            }
            w.setTransactionSuccessful()
        } finally { w.endTransaction() }
        Log.i("PhotoTracer", "인물 ${people.size}명 다시 붙임, ${System.currentTimeMillis() - t0}ms")
    }

    private fun dot(a: FloatArray, b: FloatArray): Float { var s = 0f; for (d in a.indices) s += a[d] * b[d]; return s }
}
