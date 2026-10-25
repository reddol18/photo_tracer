package com.reddol18.photo_tracer

import java.io.InputStream

/**
 * SigLIP 2 한국어 모델의 검색어 토크나이저 (HF tokenizers의 Gemma식 BPE를 그대로 옮김).
 *   정규화: 공백 → '▁' (앞에 공백을 붙이지 않는다). 문장 전체가 한 단어다.
 *   BPE: 글자 단위로 나눈 뒤 우선순위가 가장 높은(번호가 작은) 이웃 쌍부터 합친다. 같으면 왼쪽부터.
 *   어휘에 없는 글자는 UTF-8 바이트 토큰(<0xAB>)으로 바꾼다.
 *   끝에 <eos>, 64칸에 못 미치면 <pad>(0)로 채우고 넘치면 63개에서 자른다.
 * 파일은 poc/app_assets.py build 가 만든다. 안드로이드 API를 쓰지 않아 PC 단위 테스트로 Python과 비교한다.
 */
class Tokenizer(vocab: InputStream, merges: InputStream) {
    companion object {
        const val LEN = 64
        const val PAD = 0
        const val EOS = 1
        const val UNK = 3
    }

    private val ids = HashMap<String, Int>(40000)
    private val rank = HashMap<Long, Int>(80000)
    private val merged = HashMap<Long, Int>(80000)

    init {
        vocab.bufferedReader().useLines { lines ->
            lines.forEachIndexed { i, hex -> ids[String(hexBytes(hex), Charsets.UTF_8)] = i }
        }
        merges.bufferedReader().useLines { lines ->
            lines.forEachIndexed { r, line ->
                val (a, b, c) = line.split(' ').map { it.toInt() }
                val key = pair(a, b)
                rank[key] = r
                merged[key] = c
            }
        }
    }

    fun encode(text: String): LongArray {
        val tokens = bpe(text.replace(" ", "▁"))
        val out = LongArray(LEN) { PAD.toLong() }
        val n = minOf(tokens.size, LEN - 1)
        for (i in 0 until n) out[i] = tokens[i].toLong()
        out[n] = EOS.toLong()
        return out
    }

    private fun bpe(word: String): List<Int> {
        if (word.isEmpty()) return emptyList()
        val sym = ArrayList<Int>()
        var i = 0
        while (i < word.length) {
            val cp = word.codePointAt(i)
            val ch = String(Character.toChars(cp))
            i += ch.length
            val id = ids[ch]
            if (id != null) {
                sym.add(id)
            } else {
                // 바이트 대체. 바이트 토큰이 하나라도 없으면 그 글자 전체가 <unk> (연속된 <unk>는 하나로)
                val bytes = ch.toByteArray(Charsets.UTF_8).map { ids["<0x%02X>".format(it.toInt() and 0xFF)] }
                if (bytes.all { it != null }) bytes.forEach { sym.add(it!!) }
                else if (sym.lastOrNull() != UNK) sym.add(UNK)
            }
        }
        while (sym.size > 1) {
            var best = -1
            var bestRank = Int.MAX_VALUE
            for (k in 0 until sym.size - 1) {
                val r = rank[pair(sym[k], sym[k + 1])] ?: continue
                if (r < bestRank) { bestRank = r; best = k }
            }
            if (best < 0) break
            sym[best] = merged.getValue(pair(sym[best], sym[best + 1]))
            sym.removeAt(best + 1)
        }
        return sym
    }

    private fun pair(a: Int, b: Int): Long = (a.toLong() shl 32) or b.toLong()

    private fun hexBytes(hex: String): ByteArray =
        ByteArray(hex.length / 2) { ((Character.digit(hex[2 * it], 16) shl 4) + Character.digit(hex[2 * it + 1], 16)).toByte() }
}
