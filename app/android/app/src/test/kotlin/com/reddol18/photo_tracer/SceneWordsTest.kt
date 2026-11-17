package com.reddol18.photo_tracer

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 장면 검색어 낱말 규칙(#23·#24): 사전 낱말·조사 맞추기, 사람 낱말 판정, 영어 뜻 섞기, 흔한 방향 빼기 켜짐/꺼짐.
 * 벡터는 작은 차원의 손으로 만든 값이다.
 */
class SceneWordsTest {
    private fun v(vararg x: Float) = SceneWords.unit(x)
    private val lex = SceneWords.Lexicon(
        listOf(listOf("카트"), listOf("의자"), listOf("먹는", "먹고"), listOf("산책"), listOf("인형"), listOf("공")),
        listOf(v(1f, 0f, 0f), v(0f, 1f, 0f), v(0f, 0f, 1f), v(1f, 1f, 0f), v(0f, 1f, 1f), v(1f, 0f, 1f)))

    @Test fun 조사가_붙어도_사전_낱말을_찾는다() {
        assertEquals(listOf(0), lex.match("카트에"))
        assertEquals(listOf(1), lex.match("의자에서"))
        assertEquals(listOf(0, 1), lex.match("카트 의자"))
        assertEquals(listOf(1), lex.match("의자로"))
        assertEquals(listOf(4), lex.match("인형들과")) // 복수 '들'까지 뗀다
        assertEquals(listOf(5), lex.match("공을"))
    }

    @Test fun 하다_활용과_동사_꼴() {
        assertEquals(listOf(3), lex.match("산책하는 아이"))
        assertEquals(listOf(3), lex.match("산책한"))
        assertEquals(listOf(2), lex.match("먹는 아이"))
        assertEquals(listOf(2), lex.match("밥 먹고"))
        assertEquals(listOf(2), lex.match("먹는 먹고")) // 같은 낱말은 한 번
    }

    @Test fun 사전에_없거나_낱말_일부만_같으면_안_맞는다() {
        assertEquals(emptyList<Int>(), lex.match("바다"))
        assertEquals(emptyList<Int>(), lex.match("뽀로로"))
        assertEquals(emptyList<Int>(), lex.match("공원")) // '공'으로 시작해도 다른 낱말
        assertEquals(emptyList<Int>(), lex.match("카트라이더"))
        assertEquals(emptyList<Int>(), lex.match(""))
    }

    @Test fun 사람_낱말_판정() {
        assertTrue(SceneWords.hasPerson("먹는 아이"))
        assertTrue(SceneWords.hasPerson("바다에서 노는 아이와"))
        assertTrue(SceneWords.hasPerson("아기가 자는"))
        assertTrue(SceneWords.hasPerson("애기랑"))
        assertTrue(SceneWords.hasPerson("요리하는 모습"))
        assertTrue(SceneWords.hasPerson("아이들이"))
        assertTrue(SceneWords.hasPerson("사람들"))
        assertFalse(SceneWords.hasPerson("바다"))
        assertFalse(SceneWords.hasPerson("카트에 앉은"))
        assertFalse(SceneWords.hasPerson("아이스크림"))
        assertFalse(SceneWords.hasPerson("사람인형")) // 붙여 쓴 다른 낱말
        assertFalse(SceneWords.hasPerson(""))
    }

    @Test fun 사전_낱말이_없으면_검색어_벡터_그대로() {
        val q = v(0.2f, 0.3f, 0.9f)
        assertSame(q, lex.mix("바다", q))
        assertSame(q, lex.mix("카트", q, 0f))
        assertSame(q, SceneWords.Lexicon.EMPTY.mix("카트", q))
    }

    @Test fun 사전_낱말이_있으면_영어_뜻을_비율만큼_섞는다() {
        val q = v(0f, 0f, 1f)
        val m = lex.mix("카트에 탄 아이", q)
        assertNotSame(q, m)
        // norm(0.7·q + 0.3·카트)
        val want = v(0.3f, 0f, 0.7f)
        assertArrayEquals(want, m, 1e-6f)
        // 둘이면 영어 뜻 합을 정규화해 섞는다
        val m2 = lex.mix("카트 의자", q)
        val e = v(1f, 1f, 0f)
        assertArrayEquals(v(0.3f * e[0], 0.3f * e[1], 0.7f), m2, 1e-6f)
    }

    @Test fun 흔한_방향_빼기() {
        val c = v(1f, 0f, 0f)
        val q = v(0.6f, 0.8f, 0f)
        assertArrayEquals(floatArrayOf(0f, 0.8f, 0f), SceneWords.deCommon(q, c), 1e-6f)
    }

    @Test fun assets_형식_읽기() {
        val l = SceneWords.Lexicon.parse(listOf("카트|쇼핑카트", "의자", ""), floatArrayOf(1f, 0f, 0f, 1f), dim = 2)
        assertEquals(listOf(0), l.match("쇼핑카트에"))
        assertEquals(listOf(1), l.match("의자"))
        assertArrayEquals(floatArrayOf(0f, 1f), l.vecs[1], 0f)
    }

    /** 저장소의 사전 원본(poc/search_dict.tsv): 꼴이 겹치지 않고, 흔한 쓰임이 맞는지 */
    @Test fun 사전_원본() {
        val f = listOf("../../../poc/search_dict.tsv", "../../poc/search_dict.tsv").map(::File).firstOrNull { it.exists() }
            ?: throw AssertionError("poc/search_dict.tsv를 찾지 못했다")
        val entries = f.readLines(Charsets.UTF_8).filter { it.isNotBlank() && !it.startsWith("#") }.map { it.split("\t")[1].split("|") }
        val all = entries.flatten()
        assertEquals("사전 꼴 중복", all.size, all.toSet().size)
        assertTrue(entries.size >= 300)
        val l = SceneWords.Lexicon(entries, entries.map { floatArrayOf(0f) })
        val en = { q: String -> l.match(q).map { k -> f.readLines(Charsets.UTF_8).filter { it.isNotBlank() && !it.startsWith("#") }[k].split("\t")[2] } }
        assertEquals(listOf("shopping cart"), en("카트에"))
        assertEquals(listOf("chair"), en("의자에서"))
        assertEquals(listOf("taking a walk"), en("산책하는 아이"))
        // 캐릭터·장소는 넣지 않는다
        for (q in listOf("뽀로로", "헬로키티", "캐릭터", "바다", "공원", "카페", "마트", "아이")) assertEquals(q, emptyList<String>(), en(q))
    }
}
