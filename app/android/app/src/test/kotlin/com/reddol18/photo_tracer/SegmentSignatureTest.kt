package com.reddol18.photo_tracer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 구간 지문(#31): 스캔이 구간을 다시 만들어도 화면이 볼 것이 같으면 지문이 같고(번호를 올리지 않음),
 * 장 수·표지·번호 순서가 바뀌면 지문이 달라진다(홈이 다시 읽음).
 */
class SegmentSignatureTest {
    private fun seg(vararg ids: Long) = ids.map { it to it * 1000 }

    @Test fun 같은_구간이면_같은_지문() {
        val a = listOf(seg(1, 2, 3), seg(10, 11))
        val b = listOf(seg(1, 2, 3), seg(10, 11))
        assertEquals(Scanner.signature(a), Scanner.signature(b))
    }

    @Test fun 사진이_붙으면_달라진다() {
        assertNotEquals(Scanner.signature(listOf(seg(1, 2, 3))), Scanner.signature(listOf(seg(1, 2, 3, 4))))
    }

    @Test fun 사진이_지워지면_달라진다_구간_수는_같아도() {
        assertNotEquals(Scanner.signature(listOf(seg(1, 2, 3), seg(10, 11))), Scanner.signature(listOf(seg(1, 3), seg(10, 11))))
    }

    @Test fun 앞에_구간이_끼면_번호가_밀려_달라진다() {
        assertNotEquals(Scanner.signature(listOf(seg(10, 11))), Scanner.signature(listOf(seg(1), seg(10, 11))))
    }

    @Test fun 구간_경계만_옮겨도_달라진다() {
        assertNotEquals(Scanner.signature(listOf(seg(1, 2), seg(3, 4))), Scanner.signature(listOf(seg(1), seg(2, 3, 4))))
    }

    // #37: 구간 밖 사진('이름' 등)만 지워져 지문이 같아도, 사진이 바뀌었으면 번호를 올린다
    @Test fun 구간_밖_사진만_지워져도_번호를_올린다() {
        val sig = Scanner.signature(listOf(seg(1, 2, 3)))
        assertTrue(Scanner.shouldBump(sig, sig, photosChanged = true))
    }

    @Test fun 사진도_지문도_그대로면_안_올린다() {
        val sig = Scanner.signature(listOf(seg(1, 2, 3)))
        assertFalse(Scanner.shouldBump(sig, sig, photosChanged = false))
    }

    @Test fun 지문이_다르거나_처음이면_올린다() {
        val a = Scanner.signature(listOf(seg(1, 2, 3)))
        val b = Scanner.signature(listOf(seg(1, 2)))
        assertTrue(Scanner.shouldBump(a, b, photosChanged = false))
        assertTrue(Scanner.shouldBump(null, a, photosChanged = false))
    }

    @Test fun 대표_사진은_시간상_고르게() {
        assertEquals(setOf(1L), Scanner.chosen(listOf(1L)))
        assertEquals(setOf(2L), Scanner.chosen(listOf(1L, 2L, 3L))) // 2~3장 → 1장, 가운데
        assertEquals(setOf(1L, 3L), Scanner.chosen(listOf(0L, 1L, 2L, 3L))) // 4장 → 2장
    }
}
