package com.reddol18.photo_tracer

import ai.onnxruntime.OrtSession
import android.content.Context
import android.os.Debug
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 자연어 검색. 검색어 → 토크나이저 → 텍스트 모델 → 768차원 벡터, 구간·사진 벡터와 코사인으로 순위를 매긴다.
 * 구간 점수는 구간 안 장면 벡터들의 평균(0단계 '대표 평균': 같은 달로 좁히면 5위 안 97%).
 * 구간 밖 사진(찍은 날 모름·화면 캡처)은 한 장씩 따로 겨룬다.
 * 텍스트 모델(약 200MB)은 처음 검색할 때 열어 앱이 살아 있는 동안 둔다.
 */
class Search(private val ctx: Context) {
    companion object {
        const val TOP = 60
        private var tok: Tokenizer? = null
        private var text: OrtSession? = null
        private var bank: Bank? = null
        private var bankKey = -1
    }

    private class Bank(val kinds: List<String>, val keys: List<Long>, val vecs: List<FloatArray>)

    private val db = Db.get(ctx)
    private val models = Models(ctx)

    @Synchronized
    fun vector(query: String): FloatArray {
        val t = tok ?: models.tokenizer().also { tok = it }
        val s = text ?: models.session(Models.TEXT).also { text = it }
        return models.embedText(s, t.encode(query))
    }

    /** 결과: kind(segment|photo), id, cover(보여 줄 사진), n(장 수), date, date_source, score */
    fun search(query: String): Map<String, Any?> {
        val t0 = System.nanoTime()
        val q = vector(query)
        val tq = (System.nanoTime() - t0) / 1e6
        val b = bank()
        val scores = b.vecs.map { v -> var s = 0f; for (d in v.indices) s += v[d] * q[d]; s }
        val top = scores.indices.sortedByDescending { scores[it] }.take(TOP)
        val items = top.map { i ->
            val key = b.keys[i]
            if (b.kinds[i] == "segment") segmentItem(key, q, scores[i]) else photoItem(key, scores[i])
        }
        return mapOf("items" to items, "query_ms" to tq, "total_ms" to (System.nanoTime() - t0) / 1e6, "candidates" to b.vecs.size)
    }

    private fun segmentItem(seg: Long, q: FloatArray, score: Float): Map<String, Any?> {
        // 표지: 구간에서 검색어와 가장 닮은 장면 벡터의 사진
        var cover = 0L
        var best = -2f
        db.readableDatabase.rawQuery("SELECT v.photo_id, v.v FROM vectors v JOIN photos p ON p.id = v.photo_id WHERE p.segment = ?",
            arrayOf(seg.toString())).use {
            while (it.moveToNext()) {
                val v = Db.floats(it.getBlob(1))
                var s = 0f; for (d in v.indices) s += v[d] * q[d]
                if (s > best) { best = s; cover = it.getLong(0) }
            }
        }
        return db.readableDatabase.rawQuery("SELECT start, n FROM segments WHERE id = ?", arrayOf(seg.toString())).use {
            it.moveToFirst()
            mapOf("kind" to "segment", "id" to seg, "cover" to cover, "n" to it.getInt(1), "date" to it.getLong(0),
                  "date_source" to "카메라", "score" to score.toDouble())
        }
    }

    private fun photoItem(id: Long, score: Float): Map<String, Any?> =
        db.readableDatabase.rawQuery("SELECT taken_at, received_at, date_source FROM photos WHERE id = ?", arrayOf(id.toString())).use {
            it.moveToFirst()
            mapOf("kind" to "photo", "id" to id, "cover" to id, "n" to 1,
                  "date" to (if (it.isNull(0)) null else it.getLong(0)), "received" to (if (it.isNull(1)) null else it.getLong(1)),
                  "date_source" to it.getString(2), "score" to score.toDouble())
        }

    /** 장면 벡터나 구간이 바뀌었을 때만 다시 만든다 */
    @Synchronized
    private fun bank(): Bank {
        val n = db.count("SELECT COUNT(*) FROM vectors") * 100_003 + db.count("SELECT COUNT(*) FROM segments")
        bank?.let { if (bankKey == n) return it }
        val kinds = ArrayList<String>(); val keys = ArrayList<Long>(); val vecs = ArrayList<FloatArray>()
        val sums = LinkedHashMap<Long, FloatArray>()
        db.readableDatabase.rawQuery("SELECT p.segment, p.id, v.v FROM vectors v JOIN photos p ON p.id = v.photo_id", null).use {
            while (it.moveToNext()) {
                val v = Db.floats(it.getBlob(2))
                if (it.isNull(0)) {
                    kinds.add("photo"); keys.add(it.getLong(1)); vecs.add(v)
                } else {
                    val sum = sums.getOrPut(it.getLong(0)) { FloatArray(v.size) }
                    for (d in v.indices) sum[d] += v[d]
                }
            }
        }
        for ((seg, sum) in sums) {
            val norm = kotlin.math.sqrt(sum.sumOf { (it * it).toDouble() }).toFloat()
            kinds.add("segment"); keys.add(seg); vecs.add(FloatArray(sum.size) { sum[it] / norm })
        }
        return Bank(kinds, keys, vecs).also { bank = it; bankKey = n }
    }

    /**
     * 개발용: 확인용 검색어(assets/debug/queries.txt + 앱 폴더의 queries_private.txt — adb로 넣은 경우)를
     * 폰에서 토큰·벡터로 바꿔 앱 폴더에 query_vectors_<ms>.json 으로 쓴다. PC에서 poc/app_assets.py compare 로 비교.
     */
    fun exportQueryVectors(): String {
        val hex = ctx.assets.open("debug/queries.txt").bufferedReader().readLines().toMutableList()
        val dir = ctx.getExternalFilesDir(null)!!
        File(dir, "queries_private.txt").takeIf { it.exists() }?.let { hex += it.readLines() }
        val queries = hex.filter { it.isNotBlank() }
        val pssBefore = Debug.getPss() / 1024.0
        val t0 = System.nanoTime()
        val t = tok ?: models.tokenizer().also { tok = it }
        val s = text ?: models.session(Models.TEXT).also { text = it }
        val loadMs = (System.nanoTime() - t0) / 1e6
        val ids = JSONArray()
        val times = ArrayList<Double>()
        val bytes = ByteBuffer.allocate(queries.size * 768 * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (h in queries) {
            val q = String(ByteArray(h.length / 2) { h.substring(2 * it, 2 * it + 2).toInt(16).toByte() }, Charsets.UTF_8)
            val t1 = System.nanoTime()
            val tokens = t.encode(q)
            val v = models.embedText(s, tokens)
            times.add((System.nanoTime() - t1) / 1e6)
            ids.put(JSONArray(tokens.toList()))
            v.forEach { bytes.putFloat(it) }
        }
        val out = File(dir, "query_vectors_${System.currentTimeMillis()}.json")
        out.writeText(JSONObject().put("queries", JSONArray(queries)).put("ids", ids).put("dim", 768)
            .put("vectors", Base64.encodeToString(bytes.array(), Base64.NO_WRAP))
            .put("median_ms", times.sorted()[times.size / 2]).put("load_ms", loadMs)
            .put("pss_mb_before", pssBefore).put("pss_mb_after", Debug.getPss() / 1024.0).toString())
        out.setReadable(true, false) // PC가 adb로 가져갈 수 있게(앱 파일은 기본이 앱 전용)
        return out.absolutePath
    }
}
