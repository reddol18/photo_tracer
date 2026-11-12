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
import java.time.LocalDate

/**
 * 자연어 검색. 검색어 → 토크나이저 → 텍스트 모델 → 768차원 벡터, 사진 벡터와 코사인으로 순위를 매긴다.
 * 구간은 그 안에서 가장 닮은 사진의 점수로 겨루고(표지도 그 사진), 구간 밖 사진(찍은 날 모름·화면 캡처)은 한 장씩 겨룬다.
 *   실사 아닌 이미지는 맨 뒤로, 검색어는 문형 묶음으로(rank, templated 참고).
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
        private const val PERIOD_TOP = 300 // 시기만 검색할 때 보일 칸 수(#16)
        private const val POOL = 150 // debugEval: 방식별 상위 몇 칸을 후보로 내보낼지
        const val SOFT_PERSON = 0f // 장면 검색에서 뒤로 미룰 만든 이미지 점수(rank)
        // models/siglip/tags.json (export_siglip.py가 모델에서 읽은 값)
        const val LOGIT_SCALE = 112.54814f
        const val LOGIT_BIAS = -16.77151f
        private var tok: Tokenizer? = null
        private var text: OrtSession? = null
        private var bank: Bank? = null
        private var bankKey = ""
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

    /** segs[i]: 사진 i의 구간(구간 밖이면 null), fake[i]: 실사 아닌 이미지(화면 캡처·AI 그림 등, Fake.kt) */
    private class Bank(val photos: List<Long>, val segs: List<Long?>, val vecs: List<FloatArray>, val fake: List<Boolean>,
                       val person: List<Float?>) { // person: 만든 이미지 점수(Fake.kt, 카메라 정보 없는 사진만)
        fun raw(i: Int, q: FloatArray): Float { var s = 0f; val v = vecs[i]; for (d in v.indices) s += v[d] * q[d]; return s }
    }

    private val db = Db.get(ctx)
    private val models = Models(ctx)

    @Synchronized
    fun vector(query: String): FloatArray {
        val t = tok ?: models.tokenizer().also { tok = it }
        val s = text ?: models.session(Models.TEXT).also { text = it }
        return models.embedText(s, t.encode(query))
    }

    /** 결과: kind(segment|photo), id, cover(보여 줄 사진), n(장 수), date, date_source, score(코사인), conf(0~1). 흔한 방향을 뺀 점수 높은 순 */
    fun search(query: String, picks: Map<String, List<Long>> = emptyMap(), today: LocalDate = LocalDate.now()): Map<String, Any?> {
        val t0 = System.nanoTime()
        val (words, rest0) = people(query, picks)
        // 시기 말(#16): 읽은 낱말은 장면 검색어에서 빼고, 기간으로 결과를 거른다
        val toks = query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        val hit = When.parse(toks, today, { i -> words.any { isWord(toks[i], it.word) } }, FILLER)
        val (period, whenInfo) = hit?.let { whenOf(it, toks, words, picks) } ?: (null to null)
        val used = hit?.tokens?.toSet() ?: emptySet()
        val extra: Map<String, Any?> = if (whenInfo != null) mapOf("when" to whenInfo) else emptyMap()
        if (words.isNotEmpty()) {
            val rest = if (hit == null) rest0 else dropTokens(rest0, used.map { toks[it] })
            return searchPeople(words.map { it.chosen }, words.map { it.word }, rest, t0, period) + mapOf(
                // 화면의 인물 칩: 낱말, 고른 인물, 바꾸기 후보(풀이 포함), 칩 안내를 보일지
                "words" to words.map { w -> mapOf("word" to w.word, "chosen" to w.chosen.toList(),
                    "cands" to w.cands.map { mapOf("ids" to it.ids.toList(), "note" to it.note) }) },
                "hint" to !prefs.getBoolean("hint_seen", false)) + extra
        }
        val scene = toks.filterIndexed { i, _ -> i !in used }
        if (hit != null && scene.all { it in FILLER }) { // 시기만: 그 기간의 순간을 최근 순으로
            val items = periodItems(period)
            return mapOf("items" to items, "query_ms" to 0.0, "total_ms" to (System.nanoTime() - t0) / 1e6,
                         "candidates" to items.size, "rest" to "", "recent" to true) + extra
        }
        val q = templated(if (hit == null) query else scene.joinToString(" "))
        val tq = (System.nanoTime() - t0) / 1e6
        val b = bank()
        val keep = period?.let { inPeriod(it) }
        val items = rank(b, q, keep).map { c ->
            if (c.seg != null) segmentItem(c.seg, b.photos[c.cover], b.raw(c.cover, q)) else photoItem(b.photos[c.cover], b.raw(c.cover, q))
        }
        return mapOf("items" to items, "query_ms" to tq, "total_ms" to (System.nanoTime() - t0) / 1e6,
                     "candidates" to b.segs.filterNotNull().toSet().size + b.segs.count { it == null }) +
            (if (hit != null) mapOf("rest" to scene.filter { it !in FILLER }.joinToString(" ")) else emptyMap()) + extra
    }

    /** 검색어 낱말 tok이 인물 낱말 word인지: 그대로이거나 조사가 붙은 것("딸", "딸이") */
    private fun isWord(tok: String, word: String) = tok == word || JOSA.any { tok == word + it }

    /** 낱말들 중에서 drop의 낱말을 하나씩(처음 나온 것) 뺀다 */
    private fun dropTokens(text: String, drop: List<String>): String {
        val left = text.split(" ").filter { it.isNotEmpty() }.toMutableList()
        for (d in drop) left.remove(d)
        return left.joinToString(" ")
    }

    /**
     * 읽은 시기 말의 기간과 화면 칩 정보(#16). 칩: words(검색어에서 뺄 낱말), text(읽은 말), range(기간 표시),
     *   who(누구 나이인지), need: "owner"(누구 나이인지 골라야 함, cands 중에서) / "birth"(그 인물의 생년이 없음).
     * 나이 말의 인물: 검색어 속 인물(바로 앞에 있는 것 먼저) → 사용자가 칩에서 고른 인물(picks["@나이"]) → 생년이 있는 인물이 하나뿐이면 그 사람.
     * 기간을 정하지 못하면 거르지 않는다(null).
     */
    private fun whenOf(h: When.Hit, toks: List<String>, words: List<Word>, picks: Map<String, List<Long>>): Pair<Period?, Map<String, Any?>> {
        val base = mapOf("words" to h.tokens.map { toks[it] }, "text" to h.text)
        val age = h.age ?: return h.period to base + mapOf("range" to h.period!!.label())
        class Q(val id: Long, val name: String, val birth: Int?)
        val ps = ArrayList<Q>()
        db.readableDatabase.rawQuery("SELECT id, name, birth_year FROM people", null).use {
            while (it.moveToNext()) ps.add(Q(it.getLong(0), it.getString(1), if (it.isNull(2)) null else it.getInt(2)))
        }
        val wordOf = { i: Int -> words.firstOrNull { isWord(toks[i], it.word) } }
        val first = h.tokens.first()
        val owner = (first - 1 downTo 0).firstNotNullOfOrNull(wordOf) ?: toks.indices.firstNotNullOfOrNull(wordOf)
        val picked = picks["@나이"]?.firstOrNull()?.let { id -> ps.firstOrNull { it.id == id } }
        val born = ps.filter { it.birth != null }
        val (who, ids) = when {
            owner != null -> owner.word to owner.chosen.toList()
            picked != null -> picked.name to listOf(picked.id)
            born.size == 1 -> born[0].name to listOf(born[0].id)
            else -> null to emptyList()
        }
        val info = base + mapOf("age" to age.label, "who" to who)
        if (ids.isEmpty()) return null to info + mapOf("need" to (if (born.isEmpty()) "birth" else "owner"), "cands" to born.map { it.id })
        val births = ids.map { id -> ps.firstOrNull { it.id == id }?.birth }
        if (births.any { it == null }) return null to info + mapOf("need" to "birth")
        if (births.toSet().size > 1) return null to info + mapOf("need" to "owner", "cands" to ids)
        val p = age.period(births[0]!!)
        return p to info + mapOf("range" to p.label())
    }

    /** 기간 안의 구간(시작~끝이 겹치는)과 구간 밖 사진(찍은 날, 없으면 받은 날 — 짐작한 날짜도 넣는다) */
    private fun inPeriod(p: Period): Pair<Set<Long>, Set<Long>> {
        val a = p.startMs(); val z = p.endMs()
        val ids = { sql: String -> db.readableDatabase.rawQuery(sql, null).use { c -> HashSet<Long>().also { while (c.moveToNext()) it.add(c.getLong(0)) } } }
        return ids("SELECT id FROM segments WHERE start <= $z AND \"end\" >= $a") to
            ids("SELECT id FROM photos WHERE segment IS NULL AND COALESCE(taken_at, received_at) BETWEEN $a AND $z")
    }

    /** 장면 말 없이 시기만 있을 때: 기간 안의 구간·구간 밖 사진을 최근 순으로(실사 아닌 이미지는 뒤로) */
    private fun periodItems(p: Period?): List<Map<String, Any?>> {
        if (p == null) return emptyList()
        val a = p.startMs(); val z = p.endMs()
        class C(val date: Long, val fake: Boolean, val item: Map<String, Any?>)
        val cs = ArrayList<C>()
        db.readableDatabase.rawQuery("""SELECT s.id, s.start, s.n, COALESCE((SELECT id FROM photos WHERE segment = s.id AND is_rep = 1 LIMIT 1),
                (SELECT id FROM photos WHERE segment = s.id ORDER BY taken_at LIMIT 1)) FROM segments s WHERE s.start <= $z AND s."end" >= $a""", null).use {
            while (it.moveToNext()) {
                if (it.isNull(3)) continue
                cs.add(C(it.getLong(1), false, mapOf("kind" to "segment", "id" to it.getLong(0), "cover" to it.getLong(3), "n" to it.getInt(2),
                    "date" to it.getLong(1), "date_source" to "카메라")))
            }
        }
        db.readableDatabase.rawQuery("""SELECT id, taken_at, received_at, date_source, COALESCE(fake, 0) FROM photos
                WHERE segment IS NULL AND COALESCE(taken_at, received_at) BETWEEN $a AND $z""", null).use {
            val n = { i: Int -> if (it.isNull(i)) null else it.getLong(i) }
            while (it.moveToNext()) {
                val date = n(1); val received = n(2)
                cs.add(C(date ?: received!!, it.getInt(4) != 0, mapOf("kind" to "photo", "id" to it.getLong(0), "cover" to it.getLong(0), "n" to 1,
                    "date" to date, "received" to received, "date_source" to it.getString(3))))
            }
        }
        return cs.sortedWith(compareBy<C> { it.fake }.thenByDescending { it.date }).take(PERIOD_TOP).map { it.item }
    }

    /** 장면 검색의 한 칸: 구간(seg) 또는 구간 밖 사진 한 장. cover·score는 bank 안의 순번과 순위용 점수 */
    private class Cand(val seg: Long?, val cover: Int, val score: Float, val fake: Boolean)

    /**
     * 장면만 검색할 때 칸의 순위(#7). 구간은 가장 닮은 사진의 점수로 겨룬다(표지도 그 사진).
     * 실사 아닌 이미지는 실사 칸을 다 보인 뒤에만 나온다(일부러 그림을 찾을 때를 위해 빼지는 않는다):
     *   photos.fake 1·2(화면 캡처·만든 이미지), 그리고 만든 이미지 점수가 SOFT_PERSON을 넘는 카메라 정보 없는 사진.
     *   인물 찾기의 문턱(Fake.PERSON 0.005)은 실사를 빼면 안 돼서 높지만, 여기서는 뒤로 미룰 뿐이라 낮춰도 손해가 작다.
     * 폰 비교(검색어 12개 상위 12, poc/scene_rank_eval.py): 실사 아닌 이미지 바다 6·눈 4·수영장 4·생일 케이크 3·비행기 3장 → 0.
     *   구간을 위 두 장 평균으로 겨루는 것도 시험했는데, 상위 칸 대부분이 구간 밖 낱장이라 구간만 깎여 날짜 없는 AI 그림이 오히려 올라왔다.
     *   또렷함·색 다양함이 낮은 사진 뒤로 보내기도 시험했는데, 걸리는 것이 검색어마다 0~1장이고 눈 발자국 같은 진짜 사진도 걸려 넣지 않았다.
     */
    private fun rank(b: Bank, q: FloatArray, keep: Pair<Set<Long>, Set<Long>>? = null): List<Cand> {
        val (_, scores) = score(b, q)
        val back = { i: Int -> b.fake[i] || (b.person[i] ?: Float.NEGATIVE_INFINITY) > SOFT_PERSON }
        val cands = ArrayList<Cand>()
        val bySeg = HashMap<Long, MutableList<Int>>()
        for (i in scores.indices) {
            val seg = b.segs[i]
            // 시기 말(#16): 기간 안의 구간·사진만(keep = 구간 id, 구간 밖 사진 id)
            if (keep != null && (if (seg != null) seg !in keep.first else b.photos[i] !in keep.second)) continue
            if (seg == null) cands.add(Cand(null, i, scores[i], back(i))) else bySeg.getOrPut(seg) { ArrayList() }.add(i)
        }
        for ((seg, all) in bySeg) {
            val real = all.filter { !back(it) }
            val best = real.ifEmpty { all }.maxBy { scores[it] }
            cands.add(Cand(seg, best, scores[best], real.isEmpty()))
        }
        return cands.sortedWith(compareBy<Cand> { it.fake }.thenByDescending { it.score }).take(TOP)
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

    /** 인물 낱말 하나의 해석 후보. ids: 이 후보로 찾을 인물(관계가 같은 사람이 여럿이면 그중 누구든), note: 화면에 보일 풀이 */
    class Reading(val ids: Set<Long>, val note: String)

    /** 검색어 속 인물 낱말: 후보(앞이 기본 해석)와 고른 후보 */
    class Word(val word: String, val cands: List<Reading>, var chosen: Set<Long>)

    /**
     * 검색어 속 등록한 인물. 모델은 개인 이름을 모르니(이름으로 찾으면 화보·연예인 사진이 나왔다) 낱말을 인물 정보와 맞춘다.
     * 이름, 세 글자 이름은 성을 뺀 것, 관계. 조사가 붙어도("딸이랑", "엄마와") 찾는다.
     * 관계는 사용자 기준이라(#5) 같은 뜻의 다른 말(Kin.SAME)과, 함께 나온 다른 인물 입장의 말(Kin.FROM)로도 풀어 본다:
     *   "딸과 엄마" → 엄마 = 딸 입장의 엄마(아내) 또는 사용자의 엄마(할머니). 어느 쪽인지 검색어만으로 정할 수 없어
     *   다른 인물 입장 풀이를 먼저 고르고 화면에 썸네일로 보여 사용자가 바꾸게 한다(picks). 바꾼 것은 기억한다(같은 낱말·같은 짝).
     *   고른 조합으로 함께 나온 사진이 없으면, 바꾼 적 없는 낱말은 사진이 있는 다른 풀이로 바꾼다.
     * 결과: 인물 낱말들, 남은 검색어
     */
    private fun people(query: String, picks: Map<String, List<Long>>, gender: String? = prefs.getString("gender", null),
                       remember: Boolean = true): Pair<List<Word>, String> {
        class P(val id: Long, val name: String, val kin: String?)
        val ps = ArrayList<P>()
        db.readableDatabase.rawQuery("SELECT id, name, relation FROM people", null).use {
            while (it.moveToNext()) ps.add(P(it.getLong(0), it.getString(1).replace(" ", ""), it.getString(2)?.replace(" ", "")?.let(Kin::canon)))
        }
        val byName = HashMap<String, MutableSet<Long>>()
        for (p in ps) listOfNotNull(p.name, if (p.name.length == 3) p.name.substring(1) else null)
            .forEach { byName.getOrPut(it) { HashSet() }.add(p.id) }
        val withKin = { k: String -> ps.filter { it.kin == k }.map { it.id }.toSet() }

        // 1) 낱말마다 이름·관계(같은 뜻 포함)로 바로 맞는 후보. 다른 인물 입장으로만 풀리는 말(할머니 등)도 일단 둔다
        class Tok(val raw: String, val word: String, val direct: List<Reading>, val kin: String?)
        val toks = ArrayList<Tok>(); val rest = ArrayList<String>()
        for (w in query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }) {
            val forms = listOf(w) + JOSA.filter { w.length > it.length && w.endsWith(it) }.map { w.dropLast(it.length) }
            val hit = forms.firstNotNullOfOrNull { f ->
                val kin = Kin.SAME[f]
                val direct = listOfNotNull(
                    // 이름이 관계 말과 같으면("엄마"로 등록) 이름도 사용자 기준 관계로 보고, 다른 인물 입장 풀이 뒤에 둔다
                    byName[f]?.let { Reading(it, if (kin != null) "내 $kin" else f) },
                    kin?.let { withKin(it) }?.takeIf { it.isNotEmpty() }?.let { Reading(it, "내 $kin") })
                if (direct.isNotEmpty() || (kin != null && Kin.FROM.values.any { kin in it })) Tok(w, f, direct, kin) else null
            }
            if (hit != null) toks.add(hit) else if (w !in FILLER) rest.add(w)
        }
        val label = { k: String -> k }
        // 2) 다른 인물 입장의 풀이: 다른 낱말의 기본 후보 인물들의 관계에서 본 이 낱말
        val words = toks.mapIndexed { i, t ->
            val rel = ArrayList<Reading>()
            if (t.kin != null) for ((j, o) in toks.withIndex()) {
                if (j == i) continue
                val oKins = o.direct.firstOrNull()?.ids?.mapNotNull { id -> ps.first { it.id == id }.kin }?.toSet() ?: continue
                for (ok in oKins) for (k in Kin.FROM[ok]?.get(t.kin) ?: emptyList()) {
                    if (t.direct.isNotEmpty() && Kin.rank(ok) <= Kin.rank(t.kin)) continue // 위 세대 입장으로는 다시 풀지 않는다
                    if (!Kin.fits(gender, t.kin, k)) continue // 사용자 성별과 안 맞는 풀이(#10)
                    val ids = withKin(k)
                    if (ids.isNotEmpty() && rel.none { it.ids == ids }) rel.add(Reading(ids, "${label(ok)} 입장의 ${t.word} = ${if (k == "나") "나" else "내 ${label(k)}"}"))
                }
            }
            val names = t.direct.filter { !it.note.startsWith("내 ") }
            val cands = (names + rel + t.direct.filter { it.note.startsWith("내 ") }).distinctBy { it.ids }
            if (cands.isEmpty()) rest.add(t.raw) // 풀리지 않은 말은 장면 검색어로 되돌린다
            Word(t.word, cands, cands.firstOrNull()?.ids ?: emptySet())
        }.filter { it.cands.isNotEmpty() }
        // 3) 사용자가 고른 것(이번 검색 또는 기억해 둔 것)
        val others = { w: Word -> words.filter { it !== w }.joinToString(",") { it.word } }
        val fixed = HashSet<Word>()
        for (w in words) {
            if (!remember) break
            val key = "${w.word}|${others(w)}"
            val pick = picks[w.word]?.toSet()?.also { prefs.edit().putString(key, it.joinToString(",")).apply() }
                ?: prefs.getString(key, null)?.split(",")?.mapNotNull { it.toLongOrNull() }?.toSet()
            if (pick != null && pick.all { id -> ps.any { it.id == id } }) { w.chosen = pick; fixed.add(w) }
        }
        // 4) 함께 나온 사진이 없으면 바꾼 적 없는 낱말의 다른 풀이를 차례로 본다
        if (words.size > 1 && words.map { photosOf(it.chosen) }.reduce { a, b -> a intersect b }.isEmpty()) {
            for (w in words.filter { it !in fixed }) {
                val alt = w.cands.drop(1).firstOrNull { c ->
                    words.map { if (it === w) photosOf(c.ids) else photosOf(it.chosen) }.reduce { a, b -> a intersect b }.isNotEmpty()
                }
                if (alt != null) { w.chosen = alt.ids; break }
            }
        }
        return words to rest.joinToString(" ")
    }

    /** 사용자가 바꾼 인물 풀이(people)와, 칩 안내를 본 적 있는지 */
    private val prefs = ctx.getSharedPreferences("search_picks", Context.MODE_PRIVATE)
    fun hintSeen() = prefs.edit().putBoolean("hint_seen", true).apply()

    /**
     * 개발용(#5·#10): 앱 폴더에 people_eval.txt(줄마다 검색어를 UTF-8 16진수로)를 넣으면 성별 안 정함·남·여 각각으로
     * 인물 낱말 풀이를 people_eval.csv(검색어 번호, 성별, 낱말, 고른 인물 id, 후보 id와 풀이)로 쓰고 txt를 지운다.
     * 기억해 둔 선택과 사용자의 성별 설정은 쓰지도 바꾸지도 않는다. id와 관계 낱말만 나간다. 정리 화면을 열 때(scan) 확인한다.
     */
    fun debugPeople() {
        val dir = ctx.getExternalFilesDir(null) ?: return
        val list = File(dir, "people_eval.txt").takeIf { it.exists() } ?: return
        val queries = list.readLines().filter { it.isNotBlank() }
            .map { h -> String(ByteArray(h.trim().length / 2) { h.trim().substring(2 * it, 2 * it + 2).toInt(16).toByte() }, Charsets.UTF_8) }
        val out = StringBuilder("query,gender,word,chosen,cands\n")
        for ((k, q) in queries.withIndex()) for (g in listOf(null, "남", "여")) {
            val (words, _) = people(q, emptyMap(), g, remember = false)
            for (w in words) out.append("$k,${g ?: "-"},${w.word},${w.chosen.joinToString(" ")},")
                .append(w.cands.joinToString(" | ") { "${it.ids.joinToString(" ")}:${it.note}" }).append("\n")
        }
        File(dir, "people_eval.csv").apply { writeText(out.toString()); setReadable(true, false) }
        list.delete()
    }

    /** 사용자 성별("남"/"여", 정하지 않으면 null) — 관계 풀이 후보를 거른다(Kin.fits, #10) */
    fun gender(): String? = prefs.getString("gender", null)
    fun setGender(g: String?) = prefs.edit().apply { if (g == null) remove("gender") else putString("gender", g) }.apply()

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
    private fun searchPeople(groups: List<Set<Long>>, words: List<String>, rest: String, t0: Long, period: Period? = null): Map<String, Any?> {
        val ids = groups.map { photosOf(it) }.reduce { a, b -> a intersect b }
        class Row(val id: Long, val seg: Long?, val date: Long?, val received: Long?, val source: String)
        val rows = ArrayList<Row>()
        val range = period?.let { it.startMs()..it.endMs() }
        if (ids.isNotEmpty()) db.readableDatabase.rawQuery("""SELECT id, segment, taken_at, received_at, date_source FROM photos
                WHERE id IN (${ids.joinToString(",")}) ORDER BY taken_at DESC, received_at DESC""", null).use {
            val n = { i: Int -> if (it.isNull(i)) null else it.getLong(i) }
            while (it.moveToNext()) {
                val r = Row(it.getLong(0), n(1), n(2), n(3), it.getString(4))
                // 시기 말(#16): 찍은 날(없으면 받은 날)이 기간 안인 사진만. 짐작한 날짜도 넣는다
                if (range == null || (r.date ?: r.received)?.let { d -> d in range } == true) rows.add(r)
            }
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

    /** 장면 벡터, 구간, 실사 아닌 이미지 판정이 바뀌었을 때만 다시 만든다 */
    @Synchronized
    private fun bank(): Bank {
        val n = "${db.count("SELECT COUNT(*) FROM vectors")}/${db.count("SELECT COUNT(*) FROM segments")}/" +
                db.count("SELECT COUNT(*) FROM photos WHERE fake > 0")
        bank?.let { if (bankKey == n) return it }
        val photos = ArrayList<Long>(); val segs = ArrayList<Long?>(); val vecs = ArrayList<FloatArray>(); val fake = ArrayList<Boolean>()
        val person = ArrayList<Float?>()
        db.readableDatabase.rawQuery("""SELECT p.segment, p.id, v.v, COALESCE(p.fake, 0), p.fake_person
                FROM vectors v JOIN photos p ON p.id = v.photo_id""", null).use {
            while (it.moveToNext()) {
                segs.add(if (it.isNull(0)) null else it.getLong(0)); photos.add(it.getLong(1)); vecs.add(Db.floats(it.getBlob(2)))
                fake.add(it.getInt(3) != 0); person.add(if (it.isNull(4)) null else it.getFloat(4))
            }
        }
        return Bank(photos, segs, vecs, fake, person).also { bank = it; bankKey = n }
    }

    /** 사진이 얼마나 '내용 있는지': 96px 회색 썸네일의 라플라시안 분산(또렷함), RGB 표준편차 평균(색 다양함) */
    private fun detail(id: Long): Pair<Double, Double> {
        val uri = android.content.ContentUris.withAppendedId(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        val raw = ctx.contentResolver.loadThumbnail(uri, android.util.Size(96, 96), null)
        val bmp = android.graphics.Bitmap.createScaledBitmap(raw, 96, 96, true).also { if (it !== raw) raw.recycle() }
        val n = 96
        val px = IntArray(n * n).also { bmp.getPixels(it, 0, n, 0, 0, n, n) }
        bmp.recycle()
        val g = DoubleArray(px.size) { val c = px[it]; 0.299 * (c shr 16 and 255) + 0.587 * (c shr 8 and 255) + 0.114 * (c and 255) }
        var sum = 0.0; var sq = 0.0; var k = 0
        for (y in 1 until n - 1) for (x in 1 until n - 1) {
            val i = y * n + x
            val l = g[i - 1] + g[i + 1] + g[i - n] + g[i + n] - 4 * g[i]
            sum += l; sq += l * l; k++
        }
        val std = (0..2).map { ch ->
            val v = px.map { (it shr (16 - 8 * ch) and 255).toDouble() }
            val m = v.average(); kotlin.math.sqrt(v.sumOf { (it - m) * (it - m) } / v.size)
        }.average()
        return (sq / k - (sum / k) * (sum / k)) to std
    }

    /**
     * 검색어 문형 묶음(#7): 검색어, '… 사진', '… 장면' 세 벡터의 평균을 다시 정규화. 장면만 검색할 때 쓴다.
     * 폰 비교에서 바다·눈·생일 케이크는 그 장면 사진이 더 올라오고 회색 빈 사진·광고 캡처가 빠졌다. 비행기는 비슷(애초에 맞는 사진이 적다).
     * 텍스트 모델을 세 번 돌려 검색어 계산 시간이 그만큼 는다.
     */
    private fun templated(query: String): FloatArray {
        val vs = listOf(query, "$query 사진", "$query 장면").map { vector(it) }
        val m = FloatArray(vs[0].size) { d -> vs.sumOf { it[d].toDouble() }.toFloat() }
        val len = kotlin.math.sqrt(m.sumOf { (it * it).toDouble() }).toFloat()
        return FloatArray(m.size) { m[it] / len }
    }

    /**
     * 개발용(#7): 앱 폴더에 search_eval.txt(줄마다 검색어를 UTF-8 16진수로)를 adb로 넣으면, 검색어마다 후보 칸을
     * search_eval.csv로 쓰고 txt를 지운다. 순위 방식은 PC(poc/scene_rank_eval.py)에서 이 숫자들로 다시 계산해 비교한다.
     *   후보 = 낱말 검색어(a)와 문형 묶음(b, templated) 각각의 상위 POOL칸 합집합(실사 아닌 이미지도 함께)
     *   열: 검색어 번호, 칸 종류, 칸 id, 그리고 a·b마다 표지 사진·순위용 점수·실사 판정(0 실사 1 캡처 2 만든 이미지)·
     *       만든 이미지 점수·또렷함·색 다양함(detail)
     * 사진 번호와 점수만 나간다(벡터·사진은 폰 밖으로 안 나감). 정리 화면을 열 때(scan) 확인한다.
     */
    fun debugEval() {
        val dir = ctx.getExternalFilesDir(null) ?: return
        val list = File(dir, "search_eval.txt").takeIf { it.exists() } ?: return
        val queries = list.readLines().filter { it.isNotBlank() }
            .map { h -> String(ByteArray(h.trim().length / 2) { h.trim().substring(2 * it, 2 * it + 2).toInt(16).toByte() }, Charsets.UTF_8) }
        val b = bank()
        val details = HashMap<Long, Pair<Double, Double>>()
        val d = { id: Long -> details.getOrPut(id) { try { detail(id) } catch (e: Exception) { -1.0 to -1.0 } } }
        val out = StringBuilder("query,kind,id,cover_a,score_a,fake_a,person_a,lap_a,std_a,cover_b,score_b,fake_b,person_b,lap_b,std_b\n")
        for ((k, query) in queries.withIndex()) {
            // 칸마다 가장 닮은 사진(구간은 그 안에서 가장 높은 사진, 표지와 점수)
            val best = { q: FloatArray ->
                val (_, s) = score(b, q)
                val m = HashMap<String, Int>()
                for (i in s.indices) {
                    val key = b.segs[i]?.let { "segment,$it" } ?: "photo,${b.photos[i]}"
                    if ((m[key]?.let { s[it] } ?: Float.NEGATIVE_INFINITY) < s[i]) m[key] = i
                }
                m to s
            }
            val t1 = System.nanoTime(); val qa = vector(query)
            val t2 = System.nanoTime(); val qb = templated(query)
            android.util.Log.i("PhotoTracer", "search_eval 검색어 $k: 낱말 ${(t2 - t1) / 1_000_000}ms, 문형 묶음 ${(System.nanoTime() - t2) / 1_000_000}ms")
            val (ma, sa) = best(qa); val (mb, sb) = best(qb)
            val pool = (ma.keys.sortedByDescending { sa[ma[it]!!] }.take(POOL) + mb.keys.sortedByDescending { sb[mb[it]!!] }.take(POOL)).toSet()
            val fakeOf = { i: Int -> db.count("SELECT COALESCE(fake, 0) FROM photos WHERE id = ${b.photos[i]}") }
            for (key in pool) {
                out.append("$k,$key")
                for ((m, s) in listOf(ma to sa, mb to sb)) {
                    val i = m[key]!!; val (lap, std) = d(b.photos[i])
                    out.append(",${b.photos[i]},${"%.5f".format(s[i])},${fakeOf(i)},${b.person[i]?.let { "%.5f".format(it) } ?: ""}")
                        .append(",${"%.1f".format(lap)},${"%.1f".format(std)}")
                }
                out.append("\n")
            }
        }
        File(dir, "search_eval.csv").apply { writeText(out.toString()); setReadable(true, false) }
        list.delete()
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
