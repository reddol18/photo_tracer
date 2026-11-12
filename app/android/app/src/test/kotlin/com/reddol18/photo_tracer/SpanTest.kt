package com.reddol18.photo_tracer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/**
 * 기간 거르기(#17): 공통 기준 Span(구간은 겹치면, 사진은 찍은 날 없으면 받은 날)과 기간 시트의 나이·달 → 기간.
 * 시간대는 서울로 고정한다. 생년은 시험용 값이다.
 */
class SpanTest {
    private val zone = ZoneId.of("Asia/Seoul")
    private fun ms(s: String) = LocalDate.parse(s).atStartOfDay(zone).toInstant().toEpochMilli()
    private val y2023 = Span.of(Period.years(2023), zone)

    @Test fun 구간은_기간과_겹치면_넣는다() {
        assertTrue(y2023.hasSegment(ms("2022-12-30"), ms("2023-01-02"))) // 해를 넘긴 여행
        assertTrue(y2023.hasSegment(ms("2023-05-01"), ms("2023-05-03")))
        assertTrue(y2023.hasSegment(ms("2023-12-31") + 3_600_000, ms("2024-01-01") + 3_600_000))
        assertFalse(y2023.hasSegment(ms("2022-12-01"), ms("2022-12-31") + 3_600_000))
        assertFalse(y2023.hasSegment(ms("2024-01-01"), ms("2024-01-02")))
    }

    @Test fun 사진은_찍은_날_없으면_받은_날() {
        assertTrue(y2023.hasPhoto(ms("2023-06-01"), null))
        assertTrue(y2023.hasPhoto(null, ms("2023-06-01")))
        assertFalse(y2023.hasPhoto(ms("2022-06-01"), ms("2023-06-01"))) // 찍은 날이 먼저
        assertFalse(y2023.hasPhoto(null, null)) // 날짜 전혀 없는 사진은 기간이 걸리면 빠진다
        assertTrue(y2023.hasPhoto(ms("2023-12-31") + 86_399_999, null)) // 마지막 날 끝까지
        assertFalse(y2023.hasPhoto(ms("2024-01-01"), null))
    }

    @Test fun SQL_조각은_같은_경계() {
        val s = Span(10, 20)
        assertEquals("s.start <= 20 AND s.\"end\" >= 10", s.segmentSql("s."))
        assertEquals("COALESCE(p.taken_at, p.received_at) BETWEEN 10 AND 20", s.photoSql("p."))
    }

    @Test fun 화면이_보낸_from_to() {
        assertNull(Span.of(null, null))
        val half = Span.of(ms("2023-01-01"), null)!!
        assertTrue(half.hasPhoto(ms("2030-01-01"), null))
        assertFalse(half.hasPhoto(ms("2022-01-01"), null))
    }

    private fun age(kind: String, n: Int = 0) = When.Age(kind, n, false)

    @Test fun 나이_범위는_검색어_나이와_같은_규칙() {
        // 한 나이: 검색어 "딸 1살 때"(Age.period)와 같다 — 연 나이, 1살 = 생년 + 1 한 해
        assertEquals(age("살", 1).period(2023), When.ageRange(2023, age("살", 1)))
        assertEquals(Period.years(2024, 2025), When.ageRange(2023, age("살", 1), age("살", 2)))
        // 순서가 바뀌어도 같은 기간
        assertEquals(Period.years(2024, 2025), When.ageRange(2023, age("살", 2), age("살", 1)))
        // 백일 ~ 돌: 백일의 처음(생년 1월 1일 + 99일) ~ 돌의 끝(생년 + 1 12월 31일)
        assertEquals(Period(LocalDate.of(2023, 4, 10), LocalDate.of(2024, 12, 31)), When.ageRange(2023, age("백일"), age("돌")))
        // 유치원 ~ 초등학생: 생년 + 4 3월 ~ 생년 + 13 2월 끝
        assertEquals(Period(LocalDate.of(2022, 3, 1), LocalDate.of(2031, 2, 28)), When.ageRange(2018, age("유치원"), age("초등")))
    }

    @Test fun 나이_범위의_말() {
        assertEquals("1살", When.ageLabel(age("살", 1), age("살", 1)))
        assertEquals("1~2살", When.ageLabel(age("살", 2), age("살", 1)))
        assertEquals("돌~3살", When.ageLabel(age("돌"), age("살", 3)))
        assertEquals("유치원~초등학생", When.ageLabel(age("유치원"), age("초등")))
    }

    @Test fun 시트가_고른_것을_기간으로() {
        val a = When.sheet(mapOf("kind" to "age", "birth" to 2023, "a" to mapOf("kind" to "살", "n" to 1), "b" to mapOf("kind" to "살", "n" to 2)), zone)
        assertEquals("1~2살", a["age"]); assertEquals("2024~2025년", a["range"])
        assertEquals(ms("2024-01-01"), a["from"]); assertEquals(ms("2026-01-01") - 1, a["to"])
        val y = When.sheet(mapOf("kind" to "months", "y1" to 2023, "m1" to 1, "y2" to 2023, "m2" to 12), zone)
        assertEquals("2023년", y["range"])
        val m = When.sheet(mapOf("kind" to "months", "y1" to 2023, "m1" to 8, "y2" to 2023, "m2" to 3), zone) // 앞뒤 바뀜
        assertEquals("2023.3~2023.8", m["range"])
        assertEquals(ms("2023-03-01"), m["from"]); assertEquals(ms("2023-09-01") - 1, m["to"])
    }
}
