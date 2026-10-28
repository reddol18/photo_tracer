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
 * 자연어 검색. 검색어 → 토크나이저 → 텍스트 모델 → 768차원 벡터, 사진 벡터와 코사인으로 순위를 매긴다.
 * 구간은 그 안에서 가장 닮은 사진의 점수로 겨루고(표지도 그 사진), 구간 밖 사진(찍은 날 모름·화면 캡처)은 한 장씩 겨룬다.
 *   예전에는 구간을 장면 벡터 평균(0단계 '대표 평균')으로 겨뤘는데, 평균은 점수가 낮아져 낱장 사진과 섞이면 순서가 어긋났다.
 * 흔한 검색어 방향 빼기: 앨범 대부분이 아이 사진이라 "바다에서 노는 아이"는 '바다'보다 '아이'에 끌린다.
 *   일상 문구 30개 평균(assets/search/common.bin, poc/app_assets.py common)을 검색어 벡터에서 빼고 순위를 매긴다.
 *   0단계 정답(search_rank_eval.py): '아이와 ○○' 상위10 정밀도 28→42%, 한두 낱말 검색어는 그대로(37~38%).
 * conf: SigLIP 확률 sigmoid(scale·cos + bias). 긴 설명 문장은 1위가 0.8쯤이지만 짧은 검색어는 0.3쯤이라 화면에는 숫자로 안 보인다.
 * 텍스트 모델(약 200MB)은 처음 검색할 때 열어 앱이 살아 있는 동안 둔다.
 */
class Search(private val ctx: Context) {
    companion object {
        const val TOP = 60
        // models/siglip/tags.json (export_siglip.py가 모델에서 읽은 값)
        const val LOGIT_SCALE = 112.54814f
        const val LOGIT_BIAS = -16.77151f
        private var tok: Tokenizer? = null
        private var text: OrtSession? = null
        private var bank: Bank? = null
        private var bankKey = -1
        private var common: FloatArray? = null
        // 인물 낱말 뒤에 붙는 조사(긴 것부터 떼어 본다)와, 인물 검색에서 장면 검색어로 넘기지 않을 낱말
        private val JOSA = listOf("이랑", "이하고", "이와", "이가", "이는", "이를", "이의", "이도", "이만", "에게", "한테", "하고",
            "랑", "와", "과", "의", "은", "는", "이", "가", "을", "를", "도", "만").sortedByDescending { it.length }
        private val FILLER = setOf("사진", "사진들", "같이", "함께", "나온", "있는", "찍은")
    }

    private fun common(): FloatArray = common ?: ctx.assets.open("search/common.bin").use { s ->
        val b = ByteBuffer.wrap(s.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
        FloatArray(b.remaining() / 4) { b.getFloat() }
    }.also { common = it }

    /** segs[i]: 사진 i의 구간(구간 밖이면 null) */
    private class Bank(val photos: List<Long>, val segs: List<Long?>, val vecs: List<FloatArray>)

    private val db = Db.get(ctx)
    private val models = Models(ctx)

    @Synchronized
    fun vector(query: String): FloatArray {
        val t = tok ?: models.tokenizer().also { tok = it }
        val s = text ?: models.session(Models.TEXT).also { text = it }
        return models.embedText(s, t.encode(query))
    }

    /** 결과: kind(segment|photo), id, cover(보여 줄 사진), n(장 수), date, date_source, score(코사인), conf(0~1). 흔한 방향을 뺀 점수 높은 순 */
    fun search(query: String): Map<String, Any?> {
        val t0 = System.nanoTime()
        val (groups, words, rest) = people(query)
        if (groups.isNotEmpty()) return searchPeople(groups, words, rest, t0)
        val q = vector(query)
        val tq = (System.nanoTime() - t0) / 1e6
        val b = bank()
        val (raw, scores) = score(b, q)
        // 점수 높은 사진부터 훑으며, 구간은 처음 나온(= 가장 닮은) 사진으로 한 번만 넣는다
        val seen = HashSet<Long>()
        val items = ArrayList<Map<String, Any?>>()
        for (i in scores.indices.sortedByDescending { scores[it] }) {
            val seg = b.segs[i]
            if (seg != null && !seen.add(seg)) continue
            items.add(if (seg != null) segmentItem(seg, b.photos[i], raw[i]) else photoItem(b.photos[i], raw[i]))
            if (items.size == TOP) break
        }
        return mapOf("items" to items, "query_ms" to tq, "total_ms" to (System.nanoTime() - t0) / 1e6,
                     "candidates" to b.segs.filterNotNull().toSet().size + b.segs.count { it == null })
    }

    /** 사진 벡터마다 (코사인, 흔한 방향을 뺀 순위용 점수) */
    private fun score(b: Bank, q: FloatArray): Pair<List<Float>, List<Float>> {
        val c = common()
        var qc = 0f; for (d in q.indices) qc += q[d] * c[d]
        val qd = FloatArray(q.size) { q[it] - qc * c[it] }
        val raw = b.vecs.map { v -> var s = 0f; for (d in v.indices) s += v[d] * q[d]; s }
        val scores = b.vecs.map { v -> var s = 0f; for (d in v.indices) s += v[d] * qd[d]; s } // 순위용(크기 무관)
        return raw to scores
    }

    /**
     * 검색어 속 등록한 인물. 모델은 개인 이름을 모르니(이름으로 찾으면 화보·연예인 사진이 나왔다) 낱말을 인물 정보와 맞춘다.
     * 이름, 세 글자 이름은 성을 뺀 것, 관계. 조사가 붙어도("딸이랑", "엄마와") 찾는다.
     * 결과: 낱말마다 인물 id 묶음(관계가 같은 사람이 여럿이면 그중 누구든), 맞춘 낱말, 남은 검색어
     */
    private fun people(query: String): Triple<List<Set<Long>>, List<String>, String> {
        val keys = HashMap<String, MutableSet<Long>>()
        db.readableDatabase.rawQuery("SELECT id, name, relation FROM people", null).use {
            while (it.moveToNext()) {
                val name = it.getString(1).replace(" ", "")
                listOfNotNull(name, if (name.length == 3) name.substring(1) else null, it.getString(2)?.replace(" ", ""))
                    .filter { k -> k.isNotEmpty() }.forEach { k -> keys.getOrPut(k) { HashSet() }.add(it.getLong(0)) }
            }
        }
        val groups = ArrayList<Set<Long>>(); val words = ArrayList<String>(); val rest = ArrayList<String>()
        for (w in query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }) {
            val k = (listOf(w) + JOSA.filter { w.length > it.length && w.endsWith(it) }.map { w.dropLast(it.length) })
                .firstOrNull { it in keys }
            if (k != null) { groups.add(keys[k]!!); words.add(k) } else if (w !in FILLER) rest.add(w)
        }
        return Triple(groups, words, rest.joinToString(" "))
    }

    /** 인물의 사진: 정답 + 찾음(실사 아닌 이미지는 빼고). '확인 필요'는 넣지 않는다 */
    private fun photosOf(ids: Set<Long>): Set<Long> {
        val list = ids.joinToString(",")
        return db.readableDatabase.rawQuery("""SELECT f.photo_id FROM faces f JOIN photos p ON p.id = f.photo_id
                WHERE f.who IN ($list) AND COALESCE(p.fake, 0) = 0
                UNION SELECT f.photo_id FROM face_marks m JOIN faces f ON f.id = m.face_id WHERE m.ok = 1 AND m.person IN ($list)""", null)
            .use { c -> HashSet<Long>().also { while (c.moveToNext()) it.add(c.getLong(0)) } }
    }

    /**
     * 인물이 든 검색: 인물 사진만 후보로(여러 인물이면 모두 나온 사진). 구간은 그 안의 인물 사진끼리 묶어 한 칸으로.
     * 남은 낱말이 있으면("딸 바다") 그 구간·사진의 장면 점수로 순위를 매기고, 없으면 최근 순.
     * 장면 벡터는 구간 대표와 구간 밖 사진에만 있어서, 구간은 구간의 점수로 겨룬다(일반 검색과 같다).
     * 결과 칸에 ids(그 칸의 인물 사진)를 넣어, 누르면 구간 전체가 아니라 인물 사진만 보인다.
     */
    private fun searchPeople(groups: List<Set<Long>>, words: List<String>, rest: String, t0: Long): Map<String, Any?> {
        val ids = groups.map { photosOf(it) }.reduce { a, b -> a intersect b }
        class Row(val id: Long, val seg: Long?, val date: Long?, val received: Long?, val source: String)
        val rows = ArrayList<Row>()
        if (ids.isNotEmpty()) db.readableDatabase.rawQuery("""SELECT id, segment, taken_at, received_at, date_source FROM photos
                WHERE id IN (${ids.joinToString(",")}) ORDER BY taken_at DESC, received_at DESC""", null).use {
            val n = { i: Int -> if (it.isNull(i)) null else it.getLong(i) }
            while (it.moveToNext()) rows.add(Row(it.getLong(0), n(1), n(2), n(3), it.getString(4)))
        }
        var tq = 0.0
        val segScore = HashMap<Long, Float>(); val photoScore = HashMap<Long, Float>() // 순위용
        val segRaw = HashMap<Long, Float>(); val photoRaw = HashMap<Long, Float>()
        if (rest.isNotEmpty()) {
            val q = vector(rest)
            tq = (System.nanoTime() - t0) / 1e6
            val b = bank()
            val (raw, scores) = score(b, q)
            for (i in scores.indices) {
                photoScore[b.photos[i]] = scores[i]; photoRaw[b.photos[i]] = raw[i]
                val seg = b.segs[i] ?: continue
                if (scores[i] > (segScore[seg] ?: Float.NEGATIVE_INFINITY)) { segScore[seg] = scores[i]; segRaw[seg] = raw[i] }
            }
        }
        // 구간은 한 칸으로, 구간 밖 사진은 한 장씩. rows가 최근 순이라 칸도 최근 순.
        // 점수: 칸 안 인물 사진의 장면 벡터 중 가장 높은 것(표지도 그 사진). 아직 벡터가 없으면(밤 작업 전) 구간 대표의 점수
        val cells = LinkedHashMap<String, MutableList<Row>>()
        for (r in rows) cells.getOrPut(if (r.seg != null) "s${r.seg}" else "p${r.id}") { ArrayList() }.add(r)
        val items = cells.values.map { rs ->
            val best = rs.filter { it.id in photoScore }.maxByOrNull { photoScore[it.id]!! }
            val r = best ?: rs.first(); val seg = r.seg
            val rank = if (best != null) photoScore[best.id] else seg?.let { segScore[it] }
            val raw = if (best != null) photoRaw[best.id] else seg?.let { segRaw[it] }
            rank to mapOf("kind" to (if (seg != null) "segment" else "photo"), "id" to (seg ?: r.id), "cover" to r.id, "n" to rs.size,
                "ids" to rs.map { it.id }.reversed(), "date" to r.date, "received" to r.received, "date_source" to r.source,
                "score" to raw?.toDouble(), "conf" to raw?.let { conf(it) })
        }
        val sorted = if (rest.isEmpty()) items else items.sortedByDescending { it.first ?: Float.NEGATIVE_INFINITY } // 점수 없는 칸은 뒤로, 그 안은 최근 순
        return mapOf("items" to sorted.map { it.second }, "query_ms" to tq, "total_ms" to (System.nanoTime() - t0) / 1e6,
                     "candidates" to items.size, "who" to words.joinToString(" · "), "photos" to rows.size, "rest" to rest)
    }

    private fun conf(score: Float) = 1.0 / (1.0 + kotlin.math.exp(-(LOGIT_SCALE * score + LOGIT_BIAS).toDouble()))

    private fun segmentItem(seg: Long, cover: Long, score: Float): Map<String, Any?> =
        db.readableDatabase.rawQuery("SELECT start, n FROM segments WHERE id = ?", arrayOf(seg.toString())).use {
            it.moveToFirst()
            mapOf("kind" to "segment", "id" to seg, "cover" to cover, "n" to it.getInt(1), "date" to it.getLong(0),
                  "date_source" to "카메라", "score" to score.toDouble(), "conf" to conf(score))
        }

    private fun photoItem(id: Long, score: Float): Map<String, Any?> =
        db.readableDatabase.rawQuery("SELECT taken_at, received_at, date_source FROM photos WHERE id = ?", arrayOf(id.toString())).use {
            it.moveToFirst()
            mapOf("kind" to "photo", "id" to id, "cover" to id, "n" to 1,
                  "date" to (if (it.isNull(0)) null else it.getLong(0)), "received" to (if (it.isNull(1)) null else it.getLong(1)),
                  "date_source" to it.getString(2), "score" to score.toDouble(), "conf" to conf(score))
        }

    /** 장면 벡터나 구간이 바뀌었을 때만 다시 만든다 */
    @Synchronized
    private fun bank(): Bank {
        val n = db.count("SELECT COUNT(*) FROM vectors") * 100_003 + db.count("SELECT COUNT(*) FROM segments")
        bank?.let { if (bankKey == n) return it }
        val photos = ArrayList<Long>(); val segs = ArrayList<Long?>(); val vecs = ArrayList<FloatArray>()
        db.readableDatabase.rawQuery("SELECT p.segment, p.id, v.v FROM vectors v JOIN photos p ON p.id = v.photo_id", null).use {
            while (it.moveToNext()) {
                segs.add(if (it.isNull(0)) null else it.getLong(0)); photos.add(it.getLong(1)); vecs.add(Db.floats(it.getBlob(2)))
            }
        }
        return Bank(photos, segs, vecs).also { bank = it; bankKey = n }
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
