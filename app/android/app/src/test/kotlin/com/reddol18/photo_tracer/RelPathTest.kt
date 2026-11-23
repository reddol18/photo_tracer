package com.reddol18.photo_tracer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 28용 DATA → RELATIVE_PATH 꼴 바꾸기(#26). 결과는 29의 RELATIVE_PATH처럼 끝에 '/'가 붙어야
 * SCREEN_DIRS·Fake.kt의 앞부분 비교가 그대로 맞는다.
 * 실행: app/android 에서 gradlew :app:testDebugUnitTest
 */
class RelPathTest {
    private val root = "/storage/emulated/0"

    @Test fun 일반_경로() {
        assertEquals("DCIM/Screenshots/", Scanner.relPath("/storage/emulated/0/DCIM/Screenshots/a.png", root))
        assertEquals("DCIM/Camera/", Scanner.relPath("/storage/emulated/0/DCIM/Camera/20240101_120000.jpg", root))
        assertEquals("Pictures/KakaoTalk/1/", Scanner.relPath("/storage/emulated/0/Pictures/KakaoTalk/1/x.jpg", root))
    }

    @Test fun 루트가_끝에_슬래시() {
        assertEquals("DCIM/Camera/", Scanner.relPath("/storage/emulated/0/DCIM/Camera/a.jpg", "/storage/emulated/0/"))
    }

    @Test fun 루트를_모를_때_꼴로_뗀다() {
        assertEquals("DCIM/Camera/", Scanner.relPath("/storage/emulated/0/DCIM/Camera/a.jpg", null))
        assertEquals("DCIM/Camera/", Scanner.relPath("/storage/emulated/10/DCIM/Camera/a.jpg", root)) // 다른 사용자(보안 폴더 등)
    }

    @Test fun SD카드() {
        assertEquals("DCIM/Camera/", Scanner.relPath("/storage/1A2B-3C4D/DCIM/Camera/a.jpg", root))
        assertEquals("DCIM/Screenshots/", Scanner.relPath("/storage/1A2B-3C4D/DCIM/Screenshots/s.png", root))
    }

    @Test fun 루트_바로_아래() {
        assertEquals("", Scanner.relPath("/storage/emulated/0/a.jpg", root))
        assertEquals("", Scanner.relPath("/storage/1A2B-3C4D/a.jpg", root))
    }

    @Test fun 없음() {
        assertNull(Scanner.relPath(null, root))
        assertNull(Scanner.relPath("", root))
    }
}
