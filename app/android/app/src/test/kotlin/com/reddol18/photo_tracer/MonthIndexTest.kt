package com.reddol18.photo_tracer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * 빠른 이동 막대(#19)의 연·월 목차. 시간대는 서울로 고정한다. 날짜는 시험용 가짜 값이다.
 */
class MonthIndexTest {
    private val zone = ZoneId.of("Asia/Seoul")
    private fun ms(s: String) = LocalDateTime.parse(s).atZone(zone).toInstant().toEpochMilli()
    private fun m(y: Int, mo: Int, offset: Int, n: Int) = MonthIndex.Month(y, mo, offset, n)

    @Test fun 달마다_첫_위치와_개수() {
        val starts = listOf(
            ms("2025-03-20T10:00"), ms("2025-03-02T09:00"), // 2025년 3월: 0, 1
            ms("2025-01-15T12:00"),                         // 2025년 1월: 2
            ms("2023-12-31T23:30"), ms("2023-12-01T00:00"), // 2023년 12월: 3, 4
            ms("2023-11-30T23:59"),                         // 2023년 11월: 5
        )
        assertEquals(listOf(m(2025, 3, 0, 2), m(2025, 1, 2, 1), m(2023, 12, 3, 2), m(2023, 11, 5, 1)), MonthIndex.of(starts, zone))
    }

    @Test fun 빈_목록() {
        assertEquals(emptyList<MonthIndex.Month>(), MonthIndex.of(emptyList(), zone))
    }

    @Test fun 달은_폰의_시간대로_화면_머리글과_같은_기준() {
        // 서울 1월 1일 0시 30분 = UTC로는 아직 12월 31일. 화면(DateTime 지역 시각)은 1월로 본다
        val newYear = ms("2024-01-01T00:30")
        assertEquals(listOf(m(2024, 1, 0, 1)), MonthIndex.of(listOf(newYear), zone))
        assertEquals(listOf(m(2023, 12, 0, 1)), MonthIndex.of(listOf(newYear), ZoneId.of("UTC")))
    }

    @Test fun offset으로_불러오면_그_달_첫_순간이_온다() {
        // 목록(최근 순)에서 offset 자리 순간은 그 달이고, 바로 앞 순간은 다른 달이다. 합은 전체 개수
        val rnd = java.util.Random(19)
        val base = ms("2018-01-01T00:00")
        val starts = List(500) { base + (rnd.nextDouble() * 8 * 365 * 86_400_000L).toLong() }.sortedDescending()
        val idx = MonthIndex.of(starts, zone)
        assertEquals(starts.size, idx.sumOf { it.n })
        for (e in idx) {
            val d = java.time.Instant.ofEpochMilli(starts[e.offset]).atZone(zone)
            assertEquals(e.year to e.month, d.year to d.monthValue)
            if (e.offset > 0) {
                val p = java.time.Instant.ofEpochMilli(starts[e.offset - 1]).atZone(zone)
                assertTrue(p.year * 12 + p.monthValue > e.year * 12 + e.month)
            }
        }
        // 이어 붙이면 빈틈없이 이어진다
        idx.zipWithNext().forEach { (a, b) -> assertEquals(a.offset + a.n, b.offset) }
    }
}
