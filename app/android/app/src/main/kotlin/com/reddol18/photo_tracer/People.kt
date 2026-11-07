package com.reddol18.photo_tracer

import android.content.Context
import android.util.Log
import java.io.File

/**
 * 얼굴 묶기. 0단계(cluster_faces.py)는 평균 연결 계층 군집(코사인 거리 0.45)이었는데, 얼굴이 1만 개를 넘으면
 * 거리표(1만² )가 폰 메모리에 안 들어간다. 그래서 묶음 중심과 비교하는 한 번 훑기로 근사한다:
 * 얼굴마다 가장 가까운 묶음 중심과의 거리가 0.45 안이면 넣고 중심을 고치고, 아니면 새 묶음.
 * 처음부터 묶을 때는 그 뒤 두 번 다듬는다(#6): 중심이 가까운 묶음을 합치고, 모든 얼굴을 최종 중심에 다시 붙인다
 *   (한 번 훑기는 넣을 때마다 중심이 옮겨 가 늦게 온 다른 얼굴이 섞이고, 같은 사람이 여러 묶음으로 쪼개졌다).
 * 검출 해상도에서 짧은 변 MIN_SIDE 미만 얼굴은 벡터가 흐려 묶지 않는다(인물 찾기 Who는 그대로 본다).
 *   폰 비교(정답 얼굴 175개, poc/cluster_eval.py): 정답 순도 95.7→97.4%, 그 사람 가장 큰 묶음에 든 비율 64.6→75.4%.
 *   기준을 0.50·0.55로 느슨하게 하면 묶음은 줄지만 순도가 88~94%로 떨어졌다.
 * 3장 미만 묶음은 화면에 보이지 않는다.
 *
 * 아이들끼리 섞여 묶음 중심이 흐려지므로 이 묶음은 '정답 얼굴'을 고를 때 참고로만 쓴다. 인물 찾기는 Who.kt.
 * 묶음 번호가 자꾸 바뀌지 않게, 한 번 생긴 뒤에는 새 얼굴만 기존 묶음에 붙인다(assign). full은 처음부터 다시.
 */
class People(private val ctx: Context) {
    companion object {
        const val THRESHOLD = 0.45f
        const val MIN_SHOW = 3
        const val MIN_SIDE = 48
        // 검출 해상도(Models.DETECT_LONG_SIDE로 줄인 사진)에서 얼굴 상자의 짧은 변이 MIN_SIDE 이상 (load의 p = photos)
        private val BIG = "MIN(f.w * p.w, f.h * p.h) * MIN(1.0, ${Models.DETECT_LONG_SIDE}.0 / MAX(p.w, p.h, 1)) >= $MIN_SIDE"
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
            // 실사 아닌 이미지(Fake.kt) 속 얼굴과 작은 얼굴은 묶지 않는다 — 다시 묶으면 빠진다
            val (ids, vecs) = load("COALESCE(p.fake, 0) = 0 AND $BIG")
            if (vecs.isEmpty()) return
            val label = group(vecs, THRESHOLD, refine = true).first
            val size = label.toList().groupingBy { it }.eachCount()
            val renumber = size.keys.sortedByDescending { size[it] }.withIndex().associate { (k, c) -> c to k + 1 }
            write(ids, label.map { renumber[it]!! }, resetManual = true)
            val ms = System.currentTimeMillis() - t0
            prefs.edit().putLong("full_at", System.currentTimeMillis()).putInt("full_faces", vecs.size).putLong("full_ms", ms)
                .putInt("added", 0).putLong("added_at", 0).apply()
            Log.i("PhotoTracer", "얼굴 ${vecs.size}개 → 묶음 ${size.size}개 (얼굴 ${MIN_SHOW}개 이상 ${size.values.count { it >= MIN_SHOW }}개), ${ms}ms")
        } finally { running = 0 }
    }

    /** 아직 묶이지 않은 얼굴(손으로 뺀 것 제외)을 기존 묶음 중심에 붙이고, 안 맞으면 새 번호로 묶는다 */
    fun assign() {
        val t0 = System.currentTimeMillis()
        val (ids, vecs) = load("f.person IS NULL AND f.manual = 0 AND COALESCE(p.fake, 0) = 0 AND $BIG")
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

    /**
     * 개발용(#6): 앱 폴더에 cluster_eval.txt(내용 상관없음)를 adb로 넣으면 묶는 방식 여러 개를 DB를 바꾸지 않고 돌려
     * cluster_eval.csv(얼굴 id·사진 id·크기·정답 인물·찾은 인물·실사 아님, 그리고 방식마다 묶음 번호와 그 묶음 중심과의 코사인)로 쓴다.
     * 번호와 점수만 나간다(얼굴 벡터는 폰 밖으로 안 나감). PC: poc/cluster_eval.py. 정리 화면을 열 때(scan) 확인한다.
     *   pass_T: 지금 방식(한 번 훑기, 중심 코사인 > T)   refine_T: + 최종 중심에 다시 붙이기·가까운 묶음 합치기 2번
     *   refine_T_mN: + 검출 해상도에서 짧은 변 N픽셀 미만 얼굴은 묶지 않음(-1)
     */
    fun debugEval() {
        val dir = ctx.getExternalFilesDir(null) ?: return
        val trigger = File(dir, "cluster_eval.txt").takeIf { it.exists() } ?: return
        trigger.delete() // 도중에 죽어도 다시 돌지 않게 먼저 지운다
        class Row(val id: Long, val photo: Long, val side: Double, val ref: Long?, val who: Long?, val fake: Int, val v: FloatArray)
        val rows = ArrayList<Row>()
        db.readableDatabase.rawQuery("""SELECT f.id, f.photo_id, f.w, f.h, ph.w, ph.h, f.who, COALESCE(ph.fake, 0), f.v,
                (SELECT m.person FROM face_marks m WHERE m.face_id = f.id AND m.ok = 1 LIMIT 1)
                FROM faces f JOIN photos ph ON ph.id = f.photo_id
                ORDER BY COALESCE(ph.taken_at, ph.received_at, 0), f.id""", null).use {
            while (it.moveToNext()) {
                val pw = it.getDouble(4); val pht = it.getDouble(5)
                val s = minOf(1.0, Models.DETECT_LONG_SIDE / maxOf(pw, pht, 1.0))
                val side = minOf(it.getDouble(2) * pw, it.getDouble(3) * pht) * s
                rows.add(Row(it.getLong(0), it.getLong(1), side, if (it.isNull(9)) null else it.getLong(9),
                    if (it.isNull(6)) null else it.getLong(6), it.getInt(7), Db.floats(it.getBlob(8))))
            }
        }
        val use = rows.indices.filter { rows[it].fake == 0 } // 묶음과 같이 실사 아닌 이미지 속 얼굴은 묶지 않는다
        val variants = LinkedHashMap<String, Pair<IntArray, FloatArray>>()
        for (t in listOf(0.55f, 0.50f, 0.45f, 0.40f)) {
            val t0 = System.currentTimeMillis()
            variants["pass_$t"] = group(use.map { rows[it].v }, t, false).let { expand(it, use, rows.size) }
            val t1 = System.currentTimeMillis()
            variants["refine_$t"] = group(use.map { rows[it].v }, t, true).let { expand(it, use, rows.size) }
            Log.i("PhotoTracer", "cluster_eval T=$t: 한 번 훑기 ${t1 - t0}ms, 다듬기 ${System.currentTimeMillis() - t1}ms")
        }
        for (t in listOf(0.50f, 0.45f)) for (m in listOf(48, 64)) {
            val keep = use.filter { rows[it].side >= m }
            variants["refine_${t}_m$m"] = group(keep.map { rows[it].v }, t, true).let { expand(it, keep, rows.size) }
        }
        val out = StringBuilder("face,photo,side,ref,who,fake")
        variants.keys.forEach { out.append(",$it,${it}_sim") }
        out.append("\n")
        for ((i, r) in rows.withIndex()) {
            out.append("${r.id},${r.photo},${"%.0f".format(r.side)},${r.ref ?: ""},${r.who ?: ""},${r.fake}")
            for ((label, sim) in variants.values) out.append(",${label[i]},${"%.3f".format(sim[i])}")
            out.append("\n")
        }
        File(dir, "cluster_eval.csv").apply { writeText(out.toString()); setReadable(true, false) }
        Log.i("PhotoTracer", "cluster_eval: 얼굴 ${rows.size}개, 방식 ${variants.size}개")
    }

    /** debugEval: 고른 얼굴(idx)만의 결과를 전체 얼굴 순서로 편다. 안 고른 얼굴은 -1 */
    private fun expand(r: Pair<IntArray, FloatArray>, idx: List<Int>, n: Int): Pair<IntArray, FloatArray> {
        val l = IntArray(n) { -1 }; val s = FloatArray(n)
        idx.forEachIndexed { k, i -> l[i] = r.first[k]; s[i] = r.second[k] }
        return l to s
    }

    /** 묶기(full·debugEval). refine: 합치기·다시 붙이기 2번. 반환: 얼굴마다 묶음 번호(0부터, 빈 번호 있음)와 그 묶음 중심과의 코사인 */
    private fun group(vecs: List<FloatArray>, t: Float, refine: Boolean): Pair<IntArray, FloatArray> {
        val dim = vecs[0].size
        val g = Groups(dim, t)
        var label = IntArray(vecs.size) { g.add(vecs[it]) }
        if (refine) repeat(2) {
            var centers = centersOf(vecs, label, dim)
            // 가까운 묶음 합치기: 큰 묶음부터, 앞서 남긴 묶음과 중심 코사인이 t를 넘으면 그쪽으로
            val size = IntArray(centers.size).also { s -> label.forEach { s[it]++ } }
            val order = centers.indices.sortedByDescending { size[it] }
            val kept = ArrayList<Int>(); val into = IntArray(centers.size)
            for (c in order) {
                val k = kept.firstOrNull { dot(centers[it], centers[c]) > 1f - t }
                if (k == null) { kept.add(c); into[c] = c } else into[c] = k
            }
            label = IntArray(label.size) { into[label[it]] }
            centers = centersOf(vecs, label, dim)
            // 최종 중심에 다시 붙이기: 가장 가까운 중심이 기준 안이면 그쪽, 아니면 혼자
            val alive = label.toSet().toList()
            var next = centers.size
            label = IntArray(vecs.size) { i ->
                var best = -1; var bs = 1f - t
                for (c in alive) { val s = dot(vecs[i], centers[c]); if (s > bs) { bs = s; best = c } }
                if (best < 0) next++ else best
            }
        }
        val centers = centersOf(vecs, label, dim)
        return label to FloatArray(vecs.size) { dot(vecs[it], centers[label[it]]) }
    }

    private fun centersOf(vecs: List<FloatArray>, label: IntArray, dim: Int): Array<FloatArray> {
        val n = (label.maxOrNull() ?: -1) + 1
        val sums = Array(n) { FloatArray(dim) }
        for (i in vecs.indices) { val s = sums[label[i]]; val v = vecs[i]; for (d in 0 until dim) s[d] += v[d] }
        return Array(n) { if (sums[it].any { x -> x != 0f }) norm(sums[it]) else sums[it] }
    }

    /** 한 번 훑기 묶음: 가장 가까운 중심이 기준 안이면 넣고 중심을 고친다. 반환: 묶음 번호(0부터) */
    private class Groups(val dim: Int, val t: Float = THRESHOLD) {
        val sums = ArrayList<FloatArray>()
        val centers = ArrayList<FloatArray>()
        val size get() = centers.size

        fun seed(sum: FloatArray) { sums.add(sum); centers.add(norm(sum)) }

        fun add(v: FloatArray): Int {
            var best = -1
            var bestSim = 1f - t
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
