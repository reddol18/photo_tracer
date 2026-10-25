package com.reddol18.photo_tracer

import android.content.Context
import android.util.Log

/**
 * 얼굴 묶기. 0단계(cluster_faces.py)는 평균 연결 계층 군집(코사인 거리 0.45)이었는데, 얼굴이 1만 개를 넘으면
 * 거리표(1만² )가 폰 메모리에 안 들어간다. 그래서 묶음 중심과 비교하는 한 번 훑기로 근사한다:
 * 얼굴마다 가장 가까운 묶음 중심과의 거리가 0.45 안이면 넣고 중심을 고치고, 아니면 새 묶음.
 * 묶음 번호는 큰 묶음부터 1, 2, … 로 다시 매긴다. 3장 미만 묶음은 화면에 보이지 않는다.
 */
class People(ctx: Context) {
    companion object {
        const val THRESHOLD = 0.45f
        const val MIN_SHOW = 3
    }

    private val db = Db.get(ctx)

    fun cluster() {
        val t0 = System.currentTimeMillis()
        val ids = ArrayList<Long>()
        val vecs = ArrayList<FloatArray>()
        db.readableDatabase.rawQuery("""SELECT f.id, f.v FROM faces f JOIN photos p ON p.id = f.photo_id
                                        ORDER BY COALESCE(p.taken_at, p.received_at, 0), f.id""", null).use {
            while (it.moveToNext()) { ids.add(it.getLong(0)); vecs.add(Db.floats(it.getBlob(1))) }
        }
        if (vecs.isEmpty()) return
        val dim = vecs[0].size
        val sums = ArrayList<FloatArray>()   // 묶음별 벡터 합
        val centers = ArrayList<FloatArray>() // 정규화한 중심
        val label = IntArray(vecs.size)
        for ((i, v) in vecs.withIndex()) {
            var best = -1
            var bestSim = 1f - THRESHOLD
            for (c in centers.indices) {
                val ctr = centers[c]
                var s = 0f
                for (d in 0 until dim) s += v[d] * ctr[d]
                if (s > bestSim) { bestSim = s; best = c }
            }
            if (best < 0) {
                sums.add(v.copyOf()); centers.add(v.copyOf()); best = centers.size - 1
            } else {
                val sum = sums[best]
                for (d in 0 until dim) sum[d] += v[d]
                val n = kotlin.math.sqrt(sum.sumOf { (it * it).toDouble() }).toFloat()
                centers[best] = FloatArray(dim) { sum[it] / n }
            }
            label[i] = best
        }
        val size = IntArray(centers.size)
        label.forEach { size[it]++ }
        val order = centers.indices.sortedByDescending { size[it] }
        val renumber = IntArray(centers.size).also { r -> order.forEachIndexed { k, c -> r[c] = k + 1 } }
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            for (i in ids.indices) w.execSQL("UPDATE faces SET person = ? WHERE id = ?", arrayOf<Any>(renumber[label[i]], ids[i]))
            w.setTransactionSuccessful()
        } finally { w.endTransaction() }
        Log.i("PhotoTracer", "얼굴 ${vecs.size}개 → 묶음 ${centers.size}개 (${MIN_SHOW}장 이상 ${size.count { it >= MIN_SHOW }}개)," +
            " ${System.currentTimeMillis() - t0}ms")
    }
}
