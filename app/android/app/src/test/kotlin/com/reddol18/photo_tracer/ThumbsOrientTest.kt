package com.reddol18.photo_tracer

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 28용 BitmapFactory 길의 EXIF orientation 반영(#26). Matrix는 단위 테스트에서 못 쓰므로
 * orientOf가 주는 (시계 방향 회전 → 좌우 뒤집기)를 점 좌표로 직접 돌려 EXIF 정의와 맞는지 본다.
 * EXIF 정의: 값마다 저장된 0행(맨 윗줄)과 0열(맨 왼줄)이 화면의 어느 변에 와야 하는지.
 * 실행: app/android 에서 gradlew :app:testDebugUnitTest
 */
class ThumbsOrientTest {
    private val w = 4 // 저장된 가로
    private val h = 3 // 저장된 세로

    /** 저장 좌표 (x, y)를 회전·뒤집기 뒤 화면 좌표로. 반환: (x, y, 화면 가로, 화면 세로) */
    private fun map(o: Thumbs.Orient, x: Int, y: Int): List<Int> {
        var px: Int; var py: Int; var pw: Int; val ph: Int
        when (o.degrees) {
            0 -> { px = x; py = y; pw = w; ph = h }
            90 -> { px = h - 1 - y; py = x; pw = h; ph = w }
            180 -> { px = w - 1 - x; py = h - 1 - y; pw = w; ph = h }
            270 -> { px = y; py = w - 1 - x; pw = h; ph = w }
            else -> error("각도 ${o.degrees}")
        }
        if (o.flipX) px = pw - 1 - px
        return listOf(px, py, pw, ph)
    }

    /** 저장된 왼쪽 위 (0,0)과 오른쪽 위 (w-1,0)이 화면에서 어디로 가는지 확인 */
    private fun check(orientation: Int, topLeft: Pair<Int, Int>, topRight: Pair<Int, Int>, swaps: Boolean) {
        val o = Thumbs.orientOf(orientation)
        assertEquals("가로세로 바뀜 orientation=$orientation", swaps, o.swapsAxes)
        val a = map(o, 0, 0)
        val b = map(o, w - 1, 0)
        assertEquals("화면 크기 orientation=$orientation", if (swaps) listOf(h, w) else listOf(w, h), a.subList(2, 4))
        assertEquals("저장 (0,0) orientation=$orientation", topLeft, a[0] to a[1])
        assertEquals("저장 (w-1,0) orientation=$orientation", topRight, b[0] to b[1])
    }

    @Test fun 정상과_모르는_값() {
        check(1, 0 to 0, w - 1 to 0, false)
        assertEquals(Thumbs.Orient(0, false), Thumbs.orientOf(0)) // UNDEFINED
        assertEquals(Thumbs.Orient(0, false), Thumbs.orientOf(99))
    }

    // 2: 0행 위, 0열 오른쪽
    @Test fun FLIP_HORIZONTAL() = check(2, w - 1 to 0, 0 to 0, false)

    // 3: 0행 아래, 0열 오른쪽
    @Test fun ROTATE_180() = check(3, w - 1 to h - 1, 0 to h - 1, false)

    // 4: 0행 아래, 0열 왼쪽
    @Test fun FLIP_VERTICAL() = check(4, 0 to h - 1, w - 1 to h - 1, false)

    // 5: 0행 왼쪽, 0열 위 (화면 가로 h, 세로 w)
    @Test fun TRANSPOSE() = check(5, 0 to 0, 0 to w - 1, true)

    // 6: 0행 오른쪽, 0열 위
    @Test fun ROTATE_90() = check(6, h - 1 to 0, h - 1 to w - 1, true)

    // 7: 0행 오른쪽, 0열 아래
    @Test fun TRANSVERSE() = check(7, h - 1 to w - 1, h - 1 to 0, true)

    // 8: 0행 왼쪽, 0열 아래
    @Test fun ROTATE_270() = check(8, 0 to w - 1, 0 to 0, true)

    @Test fun 표본_배율() {
        assertEquals(4, Thumbs.sampleSizeFor(4032, 1000)) // 4032/4=1008 ≥ 1000, /8=504
        assertEquals(1, Thumbs.sampleSizeFor(800, 1000))
        assertEquals(2, Thumbs.sampleSizeFor(2000, 1000))
    }
}
