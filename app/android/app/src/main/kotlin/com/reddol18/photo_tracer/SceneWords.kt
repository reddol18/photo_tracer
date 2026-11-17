package com.reddol18.photo_tracer

/**
 * 장면 검색어 낱말 규칙(#23·#24). poc/search_dict.py와 같은 규칙이라 둘을 함께 고친다.
 *
 * 한영 사전(#23): 시설물·가구·탈것·사물·동작 낱말(poc/search_dict.tsv → assets/search/dict.txt·dict.bin)이 검색어에 있으면
 *   한국어 검색어 벡터에 그 낱말의 영어 뜻 벡터(PC에서 미리 계산)를 MIX 비율로 섞는다. 검색할 때 텍스트 모델을 더 돌리지 않는다.
 *   캐릭터·장소·고유한 말은 사전에 없다(한국어가 낫다 — 뽀로로 2위 → 영어 127위).
 * 흔한 장면 방향 빼기(#24): 사람 낱말(아이·아기·사람·모습…)이 든 검색어에만 뺀다. "바다"처럼 사물·장소 낱말만 있으면 그대로.
 * PC 평가(poc/query_kind_eval.py --dict, 검색어 52개, 묶음 MRR 지금 → 이 설정):
 *   캐릭터·옷·소품 0.65→0.85, 동작 0.44→0.60, 시설물 0.36→0.52, 장소 0.66→0.75. 비율 0.5 이상은 동작이 떨어졌다(0.39).
 * 낱말은 공백 단위이고, 끝의 조사·'하는' 따위를 하나 떼고(복수 '들'까지) 맞춘다: "카트에" → 카트, "산책하는" → 산책, "인형들과" → 인형.
 */
object SceneWords {
    const val MIX = 0.3f

    // 낱말 끝에서 떼어 볼 꼴(긴 것부터): 조사(Search.JOSA + 장소·도구 조사)와 '하다' 활용
    private val JOSA = listOf("이랑", "이하고", "이와", "이가", "이는", "이를", "이의", "이도", "이만", "에게", "한테", "하고",
        "랑", "와", "과", "의", "은", "는", "이", "가", "을", "를", "도", "만",
        "에서는", "에서의", "에서도", "에서", "에는", "에도", "에의", "에", "으로", "로", "까지", "부터", "처럼", "이나", "나")
    private val HA = listOf("하는중", "하면서", "하는", "하고", "하기", "하다", "하며", "하러", "하던", "했던", "한", "중")
    private val SUFFIX = (JOSA + HA).distinct().sortedByDescending { it.length }

    /** 사람 낱말: 흔한 장면 방향(아이·가족 사진 문구 평균)과 겹치는 말 */
    val PERSON = setOf("아이", "아이들", "애들", "아기", "애기", "아가", "꼬마", "어린이", "유아", "남자아이", "여자아이", "남자애", "여자애",
        "사람", "사람들", "모습", "가족", "친구", "친구들", "엄마", "아빠", "딸", "아들", "동생", "언니", "누나", "오빠", "형")

    /** 낱말 그대로, 끝 꼴 하나를 뗀 것, 그리고 복수 '들'까지 뗀 것 */
    fun forms(word: String): List<String> {
        val out = ArrayList<String>().apply { add(word) }
        for (s in SUFFIX) if (word.length > s.length && word.endsWith(s)) out.add(word.dropLast(s.length))
        out.addAll(out.filter { it.length > 1 && it.endsWith("들") }.map { it.dropLast(1) })
        return out.distinct()
    }

    private fun words(query: String) = query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }

    /** 사람 낱말이 든 검색어인지(조사가 붙어도) — 흔한 장면 방향을 뺄지 */
    fun hasPerson(query: String) = words(query).any { w -> forms(w).any { it in PERSON } }

    /** 한영 사전. entries[k]: k번째 낱말의 한국어 꼴들, vecs[k]: 그 영어 뜻 벡터(정규화) */
    class Lexicon(entries: List<List<String>>, val vecs: List<FloatArray>) {
        private val index = HashMap<String, Int>().also { m -> entries.forEachIndexed { k, fs -> fs.forEach { m.putIfAbsent(it, k) } } }

        /** 검색어 속 사전 낱말의 번호(처음 나온 순, 중복 없이) */
        fun match(query: String): List<Int> =
            words(query).mapNotNull { w -> forms(w).firstNotNullOfOrNull { index[it] } }.distinct()

        /** 사전 낱말이 있으면 norm((1-MIX)·q + MIX·norm(영어 뜻 합)), 없으면 q 그대로 */
        fun mix(query: String, q: FloatArray, a: Float = MIX): FloatArray {
            val hit = match(query)
            if (hit.isEmpty() || a <= 0f) return q
            val e = unit(FloatArray(q.size) { d -> hit.sumOf { vecs[it][d].toDouble() }.toFloat() })
            return unit(FloatArray(q.size) { (1 - a) * q[it] + a * e[it] })
        }

        companion object {
            /** assets 형식: dict.txt 줄마다 꼴들을 '|'로, dict.bin 768 float32 LE씩 같은 순서 */
            fun parse(lines: List<String>, floats: FloatArray, dim: Int = 768): Lexicon {
                val entries = lines.filter { it.isNotBlank() }.map { it.split("|") }
                require(floats.size == entries.size * dim) { "사전 벡터 수가 낱말 수와 다르다" }
                return Lexicon(entries, entries.indices.map { k -> floats.copyOfRange(k * dim, (k + 1) * dim) })
            }
            val EMPTY = Lexicon(emptyList(), emptyList())
        }
    }

    /** 검색어 벡터 q에서 방향 c(정규화)를 뺀다 — 순위용이라 크기는 상관없다 */
    fun deCommon(q: FloatArray, c: FloatArray): FloatArray {
        var qc = 0f; for (d in q.indices) qc += q[d] * c[d]
        return FloatArray(q.size) { q[it] - qc * c[it] }
    }

    fun unit(v: FloatArray): FloatArray {
        val len = kotlin.math.sqrt(v.sumOf { (it * it).toDouble() }).toFloat()
        return if (len == 0f) v else FloatArray(v.size) { v[it] / len }
    }
}
