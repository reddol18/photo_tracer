package com.reddol18.photo_tracer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** 검색 결과 칸 확인(#37): 인물 검색 칸에서 지운 사진을 빼고 장 수·표지를 다시 정한다. id는 시험용 가짜 값이다. */
class MomentCheckTest {
    @Test fun 다_지웠으면_사라짐() {
        assertNull(MomentCheck.ofIds(listOf(1L, 2L), emptySet(), 1L))
    }

    @Test fun 표지가_남았으면_그대로() {
        val r = MomentCheck.ofIds(listOf(1L, 2L, 3L), setOf(2L, 3L), 3L)!!
        assertEquals(2, r["n"])
        assertEquals(3L, r["cover"])
        assertEquals(listOf(2L, 3L), r["ids"])
    }

    @Test fun 표지를_지웠으면_남은_첫_장() {
        val r = MomentCheck.ofIds(listOf(1L, 2L, 3L), setOf(2L, 3L), 1L)!!
        assertEquals(2L, r["cover"])
    }
}
