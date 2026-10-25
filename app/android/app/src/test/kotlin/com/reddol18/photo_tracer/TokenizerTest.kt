package com.reddol18.photo_tracer

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Kotlin 토크나이저가 Python(HF tokenizers)과 토큰 id까지 똑같은지 본다. 정답은 poc/app_assets.py build 가 만든다.
 *   공개 검색어: src/test/resources/tokenizer_golden.tsv (저장소 포함)
 *   가족 사진 설명 문장: eval_data/app/tokenizer_golden_private.tsv (저장소 제외, 있을 때만)
 * 실행: app/android 에서 gradlew :app:testDebugUnitTest (작업 폴더 = app/android/app)
 */
class TokenizerTest {
    private val tok = Tokenizer(File("src/main/assets/tokenizer/vocab.txt").inputStream(),
                                File("src/main/assets/tokenizer/merges.txt").inputStream())

    /** showText = false 면 틀린 문장의 내용 대신 줄 번호만 찍는다(가족 사진 설명). */
    private fun check(golden: File, showText: Boolean) {
        val rows = golden.readLines().filter { it.isNotEmpty() }
        val wrong = rows.mapIndexedNotNull { n, line ->
            val (hex, want) = line.split('\t')
            val text = String(ByteArray(hex.length / 2) { hex.substring(2 * it, 2 * it + 2).toInt(16).toByte() }, Charsets.UTF_8)
            val got = tok.encode(text).joinToString(" ")
            if (got == want) null else "${if (showText) text.take(30) else "${n + 1}번째 줄"}\n  Python $want\n  Kotlin $got"
        }
        println("${golden.name}: ${rows.size}개 중 다름 ${wrong.size}개")
        wrong.take(5).forEach { println(it) }
        assertEquals(0, wrong.size)
    }

    @Test fun publicQueries() = check(File(javaClass.classLoader!!.getResource("tokenizer_golden.tsv")!!.toURI()), true)

    @Test fun privateDescriptions() {
        val f = File("../../../eval_data/app/tokenizer_golden_private.tsv")
        if (f.exists()) check(f, false) else println("가족 사진 설명 정답 없음 — 건너뜀")
    }
}
