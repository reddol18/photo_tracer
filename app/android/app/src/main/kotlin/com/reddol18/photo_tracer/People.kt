package com.reddol18.photo_tracer

import android.content.Context
import android.util.Log

/**
 * 얼굴 묶기. 0단계(cluster_faces.py)는 평균 연결 계층 군집(코사인 거리 0.45)이었는데, 얼굴이 1만 개를 넘으면
 * 거리표(1만² )가 폰 메모리에 안 들어간다. 그래서 묶음 중심과 비교하는 한 번 훑기로 근사한다:
 * 얼굴마다 가장 가까운 묶음 중심과의 거리가 0.45 안이면 넣고 중심을 고치고, 아니면 새 묶음.
 * 3장 미만 묶음은 화면에 보이지 않는다.
 *
 * 아이들끼리 섞여 묶음 중심이 흐려지므로 이 묶음은 '정답 얼굴'을 고를 때 참고로만 쓴다. 인물 찾기는 Who.kt.
 * 묶음 번호가 자꾸 바뀌지 않게, 한 번 생긴 뒤에는 새 얼굴만 기존 묶음에 붙인다(assign). full은 처음부터 다시.
 */
class People(ctx: Context) {
    companion object {
        const val THRESHOLD = 0.45f
        const val MIN_SHOW = 3
        @Volatile var running = 0L // 처음부터 다시 묶는 중이면 시작 시각(화면을 떠났다 와도 묶는 중인지 알 수 있게)
    }

    private val db = Db.get(ctx)
    // 언제 묶었나: 마지막 full(시각, 얼굴 수, 걸린 ms)과 그 뒤 assign으로 붙인 얼굴 수·시각. 다시 묶기 예상 시간에 쓴다
    private val prefs = ctx.getSharedPreferences("clusters", Context.MODE_PRIVATE)

    /** 화면용: 마지막으로 묶은 때와 다시 묶을 때 예상 시간. 기록이 없으면(이 기능 전에 묶음) full_at = 0 */
    fun info(): Map<String, Any?> = mapOf(
        "full_at" to prefs.getLong("full_at", 0), "full_faces" to prefs.getInt("full_faces", 0),
        "full_ms" to prefs.getLong("full_ms", 0), "added" to prefs.getInt("added", 0), "added_at" to prefs.getLong("added_at", 0),
        "faces" to db.count("SELECT COUNT(*) FROM faces"), "running" to running)

    /** 밤 작업이 끝났을 때: 묶음이 없으면 처음부터, 있으면 새 얼굴만 붙인다 */
    fun cluster() = synchronized(People) {
        if (db.count("SELECT COUNT(*) FROM faces WHERE person IS NOT NULL") == 0) full() else assign()
    }

    /** 처음부터 다시 묶기. 묶음 번호는 큰 묶음부터 1, 2, … */
    fun full(): Unit = synchronized(People) { // 밤 작업의 cluster()와 겹치지 않게
        val t0 = System.currentTimeMillis()
        running = t0
        try {
            val (ids, vecs) = load("COALESCE(p.fake, 0) = 0") // 실사 아닌 이미지(Fake.kt) 속 얼굴은 묶지 않는다 — 다시 묶으면 빠진다
            if (vecs.isEmpty()) return
            val g = Groups(vecs[0].size)
            val label = IntArray(vecs.size) { g.add(vecs[it]) }
            val size = IntArray(g.size).also { s -> label.forEach { s[it]++ } }
            val order = (0 until g.size).sortedByDescending { size[it] }
            val renumber = IntArray(g.size).also { r -> order.forEachIndexed { k, c -> r[c] = k + 1 } }
            write(ids, label.map { renumber[it] }, resetManual = true)
            val ms = System.currentTimeMillis() - t0
            prefs.edit().putLong("full_at", System.currentTimeMillis()).putInt("full_faces", vecs.size).putLong("full_ms", ms)
                .putInt("added", 0).putLong("added_at", 0).apply()
            Log.i("PhotoTracer", "얼굴 ${vecs.size}개 → 묶음 ${g.size}개 (${MIN_SHOW}장 이상 ${size.count { it >= MIN_SHOW }}개), ${ms}ms")
        } finally { running = 0 }
    }

    /** 아직 묶이지 않은 얼굴(손으로 뺀 것 제외)을 기존 묶음 중심에 붙이고, 안 맞으면 새 번호로 묶는다 */
    fun assign() {
        val t0 = System.currentTimeMillis()
        val (ids, vecs) = load("f.person IS NULL AND f.manual = 0 AND COALESCE(p.fake, 0) = 0")
        if (vecs.isEmpty()) return
        val g = Groups(vecs[0].size)
        val persons = ArrayList<Int>()
        for ((p, sum) in sums()) { g.seed(sum); persons.add(p) }
        var next = (persons.maxOrNull() ?: 0) + 1
        val out = vecs.map { v ->
            val k = g.add(v)
            if (k == persons.size) persons.add(next++)
            persons[k]
        }
        write(ids, out, resetManual = false)
        prefs.edit().putInt("added", prefs.getInt("added", 0) + vecs.size).putLong("added_at", System.currentTimeMillis()).apply()
        Log.i("PhotoTracer", "새 얼굴 ${vecs.size}개 붙임, ${System.currentTimeMillis() - t0}ms")
    }

    /**
     * 인물의 사진 목록. sim: 그 사진에 있는 이 인물 얼굴이 묶음 중심과 닮은 정도(코사인, 1에 가까울수록 닮음).
     * 묶일 때 기준이 1 - THRESHOLD(0.55)라 그 아래는 손으로 합친 것이거나 중심이 옮겨 간 것이다.
     */
    fun photos(person: Long): List<Map<String, Any>> {
        val faces = ArrayList<Triple<Long, Long, FloatArray>>() // 얼굴, 사진, 벡터
        val taken = HashMap<Long, Long>()
        db.readableDatabase.rawQuery("""SELECT f.id, f.photo_id, f.v, COALESCE(p.taken_at, p.received_at, 0)
                FROM faces f JOIN photos p ON p.id = f.photo_id WHERE f.person = ?""", arrayOf(person.toString())).use {
            while (it.moveToNext()) {
                faces.add(Triple(it.getLong(0), it.getLong(1), Db.floats(it.getBlob(2))))
                taken[it.getLong(1)] = it.getLong(3)
            }
        }
        if (faces.isEmpty()) return emptyList()
        val c = mean(faces.map { it.third })
        val best = HashMap<Long, Pair<Long, Float>>() // 사진 → 가장 닮은 얼굴
        for ((id, photo, v) in faces) {
            val s = dot(v, c)
            if ((best[photo]?.second ?: -2f) < s) best[photo] = id to s
        }
        return best.entries.sortedByDescending { taken[it.key] }.map { (photo, f) ->
            mapOf("id" to photo, "face" to f.first, "sim" to f.second.toDouble())
        }
    }

    private fun load(where: String): Pair<List<Long>, List<FloatArray>> {
        val ids = ArrayList<Long>()
        val vecs = ArrayList<FloatArray>()
        db.readableDatabase.rawQuery("""SELECT f.id, f.v FROM faces f JOIN photos p ON p.id = f.photo_id WHERE $where
                                        ORDER BY COALESCE(p.taken_at, p.received_at, 0), f.id""", null).use {
            while (it.moveToNext()) { ids.add(it.getLong(0)); vecs.add(Db.floats(it.getBlob(1))) }
        }
        return ids to vecs
    }

    /** 묶음별 얼굴 벡터 합 (중심 = 합을 정규화) */
    private fun sums(): List<Pair<Int, FloatArray>> {
        val sums = LinkedHashMap<Int, FloatArray>()
        db.readableDatabase.rawQuery("SELECT person, v FROM faces WHERE person IS NOT NULL", null).use {
            while (it.moveToNext()) {
                val v = Db.floats(it.getBlob(1))
                val s = sums.getOrPut(it.getInt(0)) { FloatArray(v.size) }
                for (d in v.indices) s[d] += v[d]
            }
        }
        return sums.toList()
    }

    private fun write(ids: List<Long>, persons: List<Int>, resetManual: Boolean) {
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            if (resetManual) w.execSQL("UPDATE faces SET person = NULL, manual = 0")
            for (i in ids.indices) w.execSQL("UPDATE faces SET person = ? WHERE id = ?", arrayOf<Any>(persons[i], ids[i]))
            w.setTransactionSuccessful()
        } finally { w.endTransaction() }
    }

    /** 한 번 훑기 묶음: 가장 가까운 중심이 기준 안이면 넣고 중심을 고친다. 반환: 묶음 번호(0부터) */
    private class Groups(val dim: Int) {
        val sums = ArrayList<FloatArray>()
        val centers = ArrayList<FloatArray>()
        val size get() = centers.size

        fun seed(sum: FloatArray) { sums.add(sum); centers.add(norm(sum)) }

        fun add(v: FloatArray): Int {
            var best = -1
            var bestSim = 1f - THRESHOLD
            for (c in centers.indices) {
                val s = dot(v, centers[c])
                if (s > bestSim) { bestSim = s; best = c }
            }
            if (best < 0) {
                sums.add(v.copyOf()); centers.add(v.copyOf()); return centers.size - 1
            }
            val sum = sums[best]
            for (d in 0 until dim) sum[d] += v[d]
            centers[best] = norm(sum)
            return best
        }
    }
}

private fun dot(a: FloatArray, b: FloatArray): Float { var s = 0f; for (d in a.indices) s += a[d] * b[d]; return s }

private fun norm(v: FloatArray): FloatArray {
    val n = kotlin.math.sqrt(v.sumOf { (it * it).toDouble() }).toFloat()
    return FloatArray(v.size) { v[it] / n }
}

private fun mean(vs: List<FloatArray>): FloatArray {
    val s = FloatArray(vs[0].size)
    for (v in vs) for (d in v.indices) s[d] += v[d]
    return norm(s)
}
