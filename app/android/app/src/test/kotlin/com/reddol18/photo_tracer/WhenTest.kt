package com.reddol18.photo_tracer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * 검색어 시기 말 읽기(#16). 오늘을 2026-11-12(목)로 고정한다.
 * 인물 낱말은 '딸'·'아들'·'인물A'로 보고(isPerson), 생년은 시험용 값이다.
 * 실행: app/android 에서 gradlew :app:testDebugUnitTest
 */
class WhenTest {
    private val today = LocalDate.of(2026, 11, 12)
    private val persons = setOf("딸", "딸이", "딸의", "아들", "아들의", "인물A")
    private val filler = setOf("사진", "사진들", "같이", "함께", "나온", "있는", "찍은")

    private fun parse(q: String): When.Hit? {
        val toks = q.split(" ").filter { it.isNotEmpty() }
        return When.parse(toks, today, { toks[it] in persons }, filler)
    }

    private fun d(s: String) = LocalDate.parse(s)
    private fun p(a: String, z: String) = Period(d(a), d(z))

    /** 절대 시기: 기간과 읽은 낱말 */
    private fun abs(q: String, a: String, z: String, tokens: List<Int>? = null) {
        val h = parse(q) ?: throw AssertionError("시기 말을 못 읽음: $q")
        assertNull(q, h.age)
        assertEquals(q, p(a, z), h.period)
        if (tokens != null) assertEquals(q, tokens, h.tokens)
    }

    /** 나이 시기: 생년 birth로 계산한 기간 */
    private fun age(q: String, birth: Int, a: String, z: String, tokens: List<Int>? = null) {
        val h = parse(q) ?: throw AssertionError("시기 말을 못 읽음: $q")
        assertNull(q, h.period)
        assertEquals(q, p(a, z), h.age!!.period(birth))
        if (tokens != null) assertEquals(q, tokens, h.tokens)
    }

    private fun none(q: String) = assertNull(q, parse(q))

    @Test fun 이슈_예문() {
        abs("작년", "2025-01-01", "2025-12-31", listOf(0))
        abs("3년 전", "2023-01-01", "2023-12-31", listOf(0, 1))
        abs("2025년", "2025-01-01", "2025-12-31")
        abs("재작년 여름", "2024-06-01", "2024-08-31", listOf(0, 1))
        age("딸 1살 때", 2018, "2019-01-01", "2019-12-31", listOf(1, 2))
        age("아들 돌 무렵", 2022, "2022-12-01", "2024-01-31", listOf(1, 2))
        abs("지난달", "2026-10-01", "2026-10-31")
        abs("올여름", "2026-06-01", "2026-08-31")
        abs("2023년 봄", "2023-03-01", "2023-05-31")
        abs("2020~2022년", "2020-01-01", "2022-12-31")
        age("1세 무렵", 2018, "2018-07-01", "2020-06-30")
        age("딸 백일", 2018, "2018-04-10", "2019-04-09")
        age("딸 초등학생 때", 2018, "2025-03-01", "2031-02-28")
    }

    @Test fun 절대_시기_여러_꼴() {
        abs("2025", "2025-01-01", "2025-12-31")
        abs("25년", "2025-01-01", "2025-12-31")
        abs("작년에 바다", "2025-01-01", "2025-12-31", listOf(0))
        abs("바다 작년 여름에", "2025-06-01", "2025-08-31", listOf(1, 2))
        abs("올해", "2026-01-01", "2026-12-31")
        abs("지난해", "2025-01-01", "2025-12-31")
        abs("지난 해", "2025-01-01", "2025-12-31")
        abs("재재작년", "2023-01-01", "2023-12-31")
        abs("3년전", "2023-01-01", "2023-12-31")
        abs("두 해 전", "2024-01-01", "2024-12-31")
        abs("3개월 전", "2026-08-01", "2026-08-31")
        abs("한 달 전", "2026-10-01", "2026-10-31")
        abs("이번 달", "2026-11-01", "2026-11-30")
        abs("지난주", "2026-11-02", "2026-11-08")
        abs("이번주", "2026-11-09", "2026-11-15")
        abs("어제", "2026-11-11", "2026-11-11")
        abs("작년 3월", "2025-03-01", "2025-03-31")
        abs("3월", "2026-03-01", "2026-03-31")
        abs("12월", "2025-12-01", "2025-12-31") // 올해 12월은 아직이라 작년
        abs("2025년 3월 10일", "2025-03-10", "2025-03-10")
        abs("2023년 겨울", "2023-12-01", "2024-02-29")
        abs("지난겨울", "2025-12-01", "2026-02-28")
        abs("지난 여름", "2026-06-01", "2026-08-31")
        abs("2020년부터 2022년까지", "2020-01-01", "2022-12-31", listOf(0, 1))
        abs("2020년 ~ 2022년", "2020-01-01", "2022-12-31", listOf(0, 1, 2))
        abs("2020-2022", "2020-01-01", "2022-12-31")
    }

    @Test fun 무렵은_넓힌다() {
        abs("2023년쯤", "2022-10-01", "2024-03-31")
        abs("2023년 무렵", "2022-10-01", "2024-03-31")
        abs("작년 여름 무렵", "2025-05-01", "2025-09-30")
        abs("3월쯤", "2026-02-01", "2026-04-30")
        assertTrue(parse("2023년쯤")!!.approx)
    }

    @Test fun 나이_여러_꼴() {
        age("세 살 때", 2018, "2021-01-01", "2021-12-31", listOf(0, 1, 2))
        age("세살때", 2018, "2021-01-01", "2021-12-31")
        age("3세", 2018, "2021-01-01", "2021-12-31")
        age("열두 살 때", 2010, "2022-01-01", "2022-12-31")
        age("인물A 다섯살", 2018, "2023-01-01", "2023-12-31", listOf(1))
        age("딸이 1살 때 바다", 2018, "2019-01-01", "2019-12-31", listOf(1, 2))
        age("1살때", 2018, "2019-01-01", "2019-12-31")
        age("18개월", 2018, "2019-07-01", "2020-06-30")
        age("딸 아기 때", 2018, "2018-01-01", "2019-12-31")
        age("아들의 돌", 2022, "2023-01-01", "2023-12-31")
        age("유치원 때", 2018, "2022-03-01", "2025-02-28")
        age("1살 무렵 사진", 2018, "2018-07-01", "2020-06-30")
        assertEquals("1살", parse("딸 1살 때")!!.age!!.label)
        assertEquals("1살 때", parse("딸 1살 때")!!.text)
    }

    @Test fun 헷갈리는_말은_장면으로() {
        none("3살 아이 장난감") // 인물도 때·무렵도 없이 나이 + 이름씨
        none("돌 위의 아이")
        none("바닷가 돌") // 돌멩이일 수 있어 끝이어도 시기로 안 본다
        none("백일 사진")
        none("아기 사진")
        none("봄 꽃") // 해 없는 계절은 장면
        none("여름 바다")
        none("해 지는 바다")
        none("경주 여행")
        none("세배")
        none("돌잔치")
        none("3년")
        none("바다")
        // 시기 말 뒤의 '경주'는 '경(무렵)+주'로 붙이지 않는다
        abs("어제 경주", "2026-11-11", "2026-11-11", listOf(0))
    }

    @Test fun 인물_끝_나이도_시기() {
        age("바다 3살", 2018, "2021-01-01", "2021-12-31", listOf(1))
        age("3살 사진", 2018, "2021-01-01", "2021-12-31", listOf(0))
        age("딸 3살 아이", 2018, "2021-01-01", "2021-12-31", listOf(1)) // 앞에 인물이 있으면 시기
    }

    @Test fun 기간_표시() {
        assertEquals("2025년", Period.years(2025).label())
        assertEquals("2020~2022년", Period.years(2020, 2022).label())
        assertEquals("2025.3", Period.months(2025, 3).label())
        assertEquals("2024.12~2025.2", Period.season(2024, 3).label())
        assertEquals("2025.3.10", p("2025-03-10", "2025-03-10").label())
        assertEquals("2018.4.10~2019.4.9", p("2018-04-10", "2019-04-09").label())
        assertEquals(p("2024-11-01", "2025-03-31"), Period.season(2024, 3).widen(months = 1))
    }
}
