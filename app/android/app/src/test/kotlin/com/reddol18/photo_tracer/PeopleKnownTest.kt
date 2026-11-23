package com.reddol18.photo_tracer

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 자주 보이는 얼굴 묶음이 '이미 등록한 사람의 묶음'으로 가는지(#28). 숫자는 S8 시험에서 본 묶음 모양을 따온 것이다.
 */
class PeopleKnownTest {
    @Test fun 이름_붙이고_나머지는_아니에요로_정리한_묶음은_등록_쪽() {
        // 얼굴 10개 = 이름 3 + 아니에요 6 + 남음 1 → 3 / (10 − 6) = 0.75
        assertTrue(People.known(total = 10, named = 3, rejected = 6))
    }

    @Test fun 아무것도_안_한_묶음은_위에_남는다() {
        assertFalse(People.known(total = 10, named = 0, rejected = 0))
    }

    @Test fun 아니에요를_분모에_넣던_예전_판정이면_남았을_묶음() {
        // 예전: 3 / 10 = 0.3 → 안 감. 아니에요가 없으면 지금도 그대로 안 감
        assertFalse(People.known(total = 10, named = 3, rejected = 0))
    }

    @Test fun 남은_얼굴이_없으면_등록_쪽() {
        assertTrue(People.known(total = 5, named = 0, rejected = 5))
        assertTrue(People.known(total = 5, named = 2, rejected = 3))
    }

    @Test fun 경계는_절반() {
        assertTrue(People.known(total = 6, named = 2, rejected = 2)) // 2 / 4 = 0.5
        assertFalse(People.known(total = 7, named = 2, rejected = 2)) // 2 / 5 = 0.4
        assertTrue(People.known(total = 4, named = 2, rejected = 0)) // 예전 판정과 같은 경우
    }

    @Test fun 아니에요만_해서는_등록_쪽으로_가지_않는다() {
        // 남은 얼굴이 있고 이름이 하나도 없으면 그대로 위에
        assertFalse(People.known(total = 10, named = 0, rejected = 6))
    }
}
