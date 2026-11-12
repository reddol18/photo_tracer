package com.reddol18.photo_tracer

import java.time.DayOfWeek
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters

/**
 * 기간: 시작~끝(양 끝 포함, 날짜 단위). 검색어 시기 말(#16)과 홈·검색 시간 거르기(#17)가 함께 쓴다.
 * 사진 날짜(ms)와 견줄 때는 폰의 시간대로 하루의 처음~끝으로 바꾼다.
 */
data class Period(val start: LocalDate, val end: LocalDate) {
    /** 앞뒤로 넓히기. 끝이 달의 마지막 날이면 넓힌 뒤에도 달의 마지막 날로(2월 28일 + 1달 = 3월 31일) */
    fun widen(months: Long = 0, days: Long = 0): Period {
        val e = end.plusMonths(months).let { if (end == end.with(TemporalAdjusters.lastDayOfMonth())) it.with(TemporalAdjusters.lastDayOfMonth()) else it }
        return Period(start.minusMonths(months).minusDays(days), e.plusDays(days))
    }

    fun startMs(zone: ZoneId = ZoneId.systemDefault()) = start.atStartOfDay(zone).toInstant().toEpochMilli()
    fun endMs(zone: ZoneId = ZoneId.systemDefault()) = end.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli() - 1

    /** 화면 표시: "2025년", "2020~2022년", "2025.3", "2024.12~2025.2", "2025.3.10", "2025.3.10~2025.4.2" */
    fun label(): String {
        val wholeMonths = start.dayOfMonth == 1 && end == end.with(TemporalAdjusters.lastDayOfMonth())
        val wholeYears = wholeMonths && start.monthValue == 1 && end.monthValue == 12
        return when {
            wholeYears && start.year == end.year -> "${start.year}년"
            wholeYears -> "${start.year}~${end.year}년"
            wholeMonths && start.withDayOfMonth(1) == end.withDayOfMonth(1) -> "${start.year}.${start.monthValue}"
            wholeMonths -> "${start.year}.${start.monthValue}~${end.year}.${end.monthValue}"
            start == end -> day(start)
            else -> "${day(start)}~${day(end)}"
        }
    }

    private fun day(d: LocalDate) = "${d.year}.${d.monthValue}.${d.dayOfMonth}"

    companion object {
        fun years(a: Int, b: Int = a) = Period(LocalDate.of(a, 1, 1), LocalDate.of(b, 12, 31))
        fun months(y: Int, m: Int, count: Long = 1): Period {
            val s = LocalDate.of(y, m, 1)
            return Period(s, s.plusMonths(count - 1).with(TemporalAdjusters.lastDayOfMonth()))
        }
        /** 계절: 0 봄(3~5월), 1 여름(6~8월), 2 가을(9~11월), 3 겨울(그해 12월~다음 해 2월) */
        fun season(y: Int, s: Int) = months(y, 3 + 3 * s, 3)
    }
}

/**
 * 검색어 속 시기 말(#16). 모델 없이 규칙으로 읽는다.
 *   절대 시기: 2025년, 2025, 25년, 작년, 지난해, 재작년, 올해, 3년 전, 두 해 전, 지난달, 이번 달, 3개월 전, 지난주, 어제,
 *             올여름, 지난겨울, 2023년 봄, 작년 3월, 3월, 2025년 3월 10일, 2020~2022년, 2020년부터 2022년까지
 *   인물 나이: 1살, 세 살, 3세, 18개월, 돌, 백일, 아기 때, 유치원·초등학생·중학생·고등학생 때 → 생년이 있어야 기간이 된다
 *   뒤에 붙는 말: 때·시절·적(그대로), 무렵·쯤·즈음·경·께·전후(넓히기), 조사(에·의·도 등)
 * 나이 말은 앞에 인물이 있거나, 뒤에 때·무렵 같은 말이 있거나, 검색어 끝(사진 같은 군말 제외)일 때만 시기로 본다.
 *   "3살 아이 장난감"은 장면으로 둔다. 돌·백일은 낱말 자체가 장면(돌멩이·백일상)일 수 있어 끝이어도 시기로 안 본다.
 * 검색어에 시기 말이 여럿이면 처음 것만 쓴다.
 */
object When {
    /** 인물 나이 기준 시기. period(생년)로 기간이 된다 */
    class Age(val kind: String, val n: Int, val approx: Boolean) {
        fun period(birth: Int): Period {
            val b0 = LocalDate.of(birth, 1, 1); val b1 = LocalDate.of(birth, 12, 31)
            return when (kind) {
                // 앱의 나이(크게 보기 이름표 'n살')는 찍은 해 - 생년이다. 그래서 n살 = 생년 + n 한 해
                "살" -> Period.years(birth + n).let { if (approx) it.widen(months = 6) else it }
                // 생일을 모르니 생년 1월 1일 ~ 12월 31일에 태어났다고 보고 그만큼 뒤
                "개월" -> Period(b0.plusMonths(n.toLong()), b1.plusMonths(n.toLong())).let { if (approx) it.widen(months = 1) else it }
                "돌" -> Period.years(birth + 1).let { if (approx) it.widen(months = 1) else it }
                "백일" -> Period(b0.plusDays(99), b1.plusDays(99)).let { if (approx) it.widen(months = 1) else it }
                "아기" -> Period.years(birth, birth + 1).let { if (approx) it.widen(months = 6) else it }
                // 학교: 만 6세가 되는 해의 다음 해 3월에 초등학교에 들어간다(생년 + 7). 유치원은 그 앞 3년
                else -> {
                    val (from, years) = when (kind) { "유치원" -> 4 to 3; "초등" -> 7 to 6; "중등" -> 13 to 3; else -> 16 to 3 }
                    Period(LocalDate.of(birth + from, 3, 1), LocalDate.of(birth + from + years, 2, 1).with(TemporalAdjusters.lastDayOfMonth()))
                        .let { if (approx) it.widen(months = 6) else it }
                }
            }
        }

        /** 칩에 보일 말: "1살", "18개월", "돌", "초등학생" */
        val label: String get() = when (kind) {
            "살" -> "${n}살"; "개월" -> "${n}개월"; "유치원" -> "유치원"; "초등" -> "초등학생"; "중등" -> "중학생"; "고등" -> "고등학생"
            else -> kind
        }
    }

    /** 읽은 시기 말. tokens: 검색어 낱말(빈칸으로 나눈) 중 시기 말이 쓴 것의 순번, period: 절대 시기, age: 나이 기준 */
    class Hit(val tokens: List<Int>, val text: String, val period: Period?, val age: Age?, val approx: Boolean)

    private enum class K { NUM, UNIT, AGO, YEAR_REL, PREFIX, SEASON, DAY_REL, AGE_WORD, SCHOOL, MARK, APPROX, TIL, END, JOSA, OTHER }

    private class P(val k: K, val s: String, val n: Int, val digits: Int, val tok: Int, var last: Boolean = false)

    private val LEX: List<Triple<String, K, Int>> = buildList {
        listOf("올해" to 0, "금년" to 0, "작년" to 1, "지난해" to 1, "재작년" to 2, "재재작년" to 3).forEach { add(Triple(it.first, K.YEAR_REL, it.second)) }
        listOf("올", "지난", "이번", "저번").forEach { add(Triple(it, K.PREFIX, 0)) }
        listOf("봄", "여름", "가을", "겨울").forEachIndexed { i, s -> add(Triple(s, K.SEASON, i)) }
        listOf("오늘" to 0, "어제" to 1, "그제" to 2, "그저께" to 2).forEach { add(Triple(it.first, K.DAY_REL, it.second)) }
        listOf("돌", "첫돌", "백일", "아기", "애기", "갓난아기").forEach { add(Triple(it, K.AGE_WORD, 0)) }
        listOf("유치원" to 0, "초등학생" to 1, "초등학교" to 1, "중학생" to 2, "중학교" to 2, "고등학생" to 3, "고등학교" to 3)
            .forEach { add(Triple(it.first, K.SCHOOL, it.second)) }
        listOf("때", "시절", "적").forEach { add(Triple(it, K.MARK, 0)) }
        listOf("무렵", "쯤", "즈음", "경", "께", "전후").forEach { add(Triple(it, K.APPROX, 0)) }
        listOf("~", "～", "-", "부터").forEach { add(Triple(it, K.TIL, 0)) }
        add(Triple("까지", K.END, 0))
        add(Triple("전", K.AGO, 0))
        listOf("년", "해", "살", "세", "개월", "달", "주", "일", "월").forEach { add(Triple(it, K.UNIT, 0)) }
        listOf("에서", "에는", "에도", "에", "엔", "의", "도", "은", "는", "이", "가").forEach { add(Triple(it, K.JOSA, 0)) }
        // 고유어 수: 한 살, 세 살, 열두 살, 스무 살, 두 해 전, 한 달 전
        val ones = listOf("한" to 1, "하나" to 1, "두" to 2, "둘" to 2, "세" to 3, "셋" to 3, "네" to 4, "넷" to 4, "다섯" to 5,
            "여섯" to 6, "일곱" to 7, "여덟" to 8, "아홉" to 9)
        ones.forEach { add(Triple(it.first, K.NUM, it.second)) }
        add(Triple("열", K.NUM, 10)); add(Triple("스무", K.NUM, 20)); add(Triple("스물", K.NUM, 20))
        ones.forEach { add(Triple("열${it.first}", K.NUM, 10 + it.second)); add(Triple("스물${it.first}", K.NUM, 20 + it.second)) }
    }

    /** 낱말 하나를 시기 조각들로. 끝까지 다 읽히지 않으면 null(시기 말이 아님) */
    private fun lex(word: String, tok: Int): List<P>? {
        val out = ArrayList<P>()
        var i = 0
        while (i < word.length) {
            if (word[i].isDigit()) {
                var j = i; while (j < word.length && word[j].isDigit()) j++
                if (j - i > 4) return null
                out.add(P(K.NUM, word.substring(i, j), word.substring(i, j).toInt(), j - i, tok)); i = j; continue
            }
            val afterNum = out.lastOrNull()?.k == K.NUM
            val cands = LEX.filter { word.startsWith(it.first, i) }
            if (cands.isEmpty()) return null
            val len = cands.maxOf { it.first.length }
            val best = cands.filter { it.first.length == len }
            // "세": 수 뒤면 단위(3세), 아니면 수(세 살)
            val e = (if (afterNum) best.firstOrNull { it.second == K.UNIT } else best.firstOrNull { it.second == K.NUM }) ?: best.first()
            out.add(P(e.second, e.first, e.third, 0, tok)); i += len
        }
        return out.ifEmpty { null }
    }

    private enum class Grain { YEAR, MONTH, WEEK, DAY }

    private fun widen(p: Period, g: Grain) = when (g) {
        Grain.YEAR -> p.widen(months = 3)
        Grain.MONTH -> p.widen(months = 1)
        Grain.WEEK -> p.widen(days = 3)
        Grain.DAY -> p.widen(days = 2)
    }

    /**
     * 검색어 낱말들에서 처음 나오는 시기 말. isPerson(i): i번째 낱말이 인물 낱말인지, filler: 끝인지 볼 때 건너뛸 군말.
     * today를 넣어 시험에서 날짜를 고정한다.
     */
    fun parse(words: List<String>, today: LocalDate, isPerson: (Int) -> Boolean = { false },
              filler: Set<String> = emptySet()): Hit? {
        val ps = ArrayList<P>()
        for ((i, w) in words.withIndex()) {
            val l = if (isPerson(i)) null else lex(w, i)
            if (l == null) ps.add(P(K.OTHER, w, 0, 0, i, true)) else { l.last().last = true; ps.addAll(l) }
        }
        for (s in ps.indices) {
            if (ps[s].k == K.OTHER || (s > 0 && !ps[s - 1].last)) continue // 낱말 처음부터만
            val hit = absolute(ps, s, today, words) ?: age(ps, s, words, isPerson, filler)
            if (hit != null) return hit
        }
        return null
    }

    private fun at(ps: List<P>, i: Int, vararg k: K) = ps.getOrNull(i)?.takeIf { it.k in k }
    private fun unit(ps: List<P>, i: Int, vararg u: String) = ps.getOrNull(i)?.takeIf { it.k == K.UNIT && it.s in u }

    /** 연도 수: 네 자리(1900~2100), 또는 '년'이 붙은 두 자리(25년 → 2025, 올해보다 뒤면 1900년대) */
    private fun yearOf(p: P, nian: Boolean, today: LocalDate): Int? = when {
        p.digits == 4 && p.n in 1900..2100 -> p.n
        p.digits == 2 && nian -> (2000 + p.n).let { if (it > today.year + 1) it - 100 else it }
        else -> null
    }

    /** 뒤에 붙는 때·무렵·조사를 읽고, 낱말 끝에서 끝낸다. 낱말 중간에서 끝나면 null */
    private class Tail(val end: Int, val approx: Boolean, val mark: Boolean)

    private fun tail(ps: List<P>, e: Int): Tail? {
        var best = if (ps[e - 1].last) Tail(e, false, false) else null
        var approx = false; var mark = false; var i = e
        while (i < ps.size && ps[i].k in setOf(K.MARK, K.APPROX, K.JOSA, K.END)) {
            if (ps[i].k == K.APPROX) approx = true
            if (ps[i].k == K.MARK || ps[i].k == K.APPROX) mark = true
            i++
            if (ps[i - 1].last) best = Tail(i, approx, mark)
        }
        return best
    }

    private fun hit(ps: List<P>, s: Int, t: Tail, words: List<String>, period: Period?, age: Age?): Hit {
        val toks = (ps[s].tok..ps[t.end - 1].tok).toList()
        return Hit(toks, toks.joinToString(" ") { words[it] }, period, age, t.approx)
    }

    private fun absolute(ps: List<P>, s: Int, today: LocalDate, words: List<String>): Hit? {
        var i = s
        var year: Int? = null
        var core: Pair<Period, Grain>? = null
        val p = ps[s]
        when {
            // 3년 전, 두 해 전, 3개월 전, 한 달 전, 2주 전, 3일 전
            p.k == K.NUM && unit(ps, s + 1, "년", "해", "개월", "달", "주", "일") != null && at(ps, s + 2, K.AGO) != null -> {
                val n = p.n.toLong()
                core = when (ps[s + 1].s) {
                    "년", "해" -> { year = today.year - p.n; null }
                    "개월", "달" -> today.minusMonths(n).let { Period.months(it.year, it.monthValue) to Grain.MONTH }
                    "주" -> week(today.minusWeeks(n)) to Grain.WEEK
                    else -> today.minusDays(n).let { Period(it, it) to Grain.DAY }
                }
                i = s + 3
            }
            // 2025년, 2025, 25년 (그리고 범위: 2020~2022년, 2020년부터 2022년까지)
            p.k == K.NUM && yearOf(p, unit(ps, s + 1, "년") != null, today) != null -> {
                year = yearOf(p, unit(ps, s + 1, "년") != null, today)
                i = s + 1 + (if (unit(ps, s + 1, "년") != null) 1 else 0)
            }
            p.k == K.NUM && p.digits == 2 && at(ps, s + 1, K.TIL) != null -> { // 20~22년: 뒤에 '년'이 있을 때만
                val b = ps.getOrNull(s + 2)
                if (b != null && b.k == K.NUM && b.digits == 2 && unit(ps, s + 3, "년") != null) {
                    val a = yearOf(p, true, today)!!; val z = yearOf(b, true, today)!!
                    if (a <= z) { core = Period.years(a, z) to Grain.YEAR; i = s + 4 }
                }
            }
            p.k == K.YEAR_REL -> { year = today.year - p.n; i = s + 1 }
            p.k == K.PREFIX && unit(ps, s + 1, "해") != null && p.s != "올" -> { year = today.year - (if (p.s == "이번") 0 else 1); i = s + 2 }
            p.k == K.PREFIX && unit(ps, s + 1, "달") != null && p.s != "올" -> {
                val m = if (p.s == "이번") today else today.minusMonths(1)
                core = Period.months(m.year, m.monthValue) to Grain.MONTH; i = s + 2
            }
            p.k == K.PREFIX && unit(ps, s + 1, "주") != null && p.s != "올" -> {
                core = week(if (p.s == "이번") today else today.minusWeeks(1)) to Grain.WEEK; i = s + 2
            }
            p.k == K.PREFIX && at(ps, s + 1, K.SEASON) != null -> {
                val se = ps[s + 1].n
                core = (if (p.s == "지난" || p.s == "저번") lastSeason(today, se) else thisSeason(today, se)) to Grain.MONTH
                i = s + 2
            }
            p.k == K.DAY_REL -> { core = today.minusDays(p.n.toLong()).let { Period(it, it) } to Grain.DAY; i = s + 1 }
            // 3월(올해 3월이 아직 안 왔으면 작년 3월)
            p.k == K.NUM && unit(ps, s + 1, "월") != null && p.n in 1..12 -> {
                val y = if (p.n <= today.monthValue) today.year else today.year - 1
                core = monthDay(ps, s, y)?.also { i = it.third }?.let { it.first to it.second }
            }
        }
        if (year != null) {
            // 범위: 2020~2022년, 2020년 ~ 2022년, 2020년부터 2022년까지
            if (p.k == K.NUM && at(ps, i, K.TIL) != null) {
                val b = ps.getOrNull(i + 1)
                val z = b?.takeIf { it.k == K.NUM }?.let { yearOf(it, unit(ps, i + 2, "년") != null || it.digits == 4, today) }
                if (z != null && z >= year) {
                    core = Period.years(year, z) to Grain.YEAR
                    i += 2 + (if (unit(ps, i + 2, "년") != null) 1 else 0)
                }
            }
            if (core == null) {
                core = when {
                    at(ps, i, K.SEASON) != null -> Period.season(year, ps[i].n).also { i++ } to Grain.MONTH
                    ps.getOrNull(i)?.k == K.NUM && unit(ps, i + 1, "월") != null && ps[i].n in 1..12 ->
                        monthDay(ps, i, year)!!.let { i = it.third; it.first to it.second }
                    else -> Period.years(year) to Grain.YEAR
                }
            }
        }
        val (period, grain) = core ?: return null
        val t = tail(ps, i) ?: return null
        return hit(ps, s, t, words, if (t.approx) widen(period, grain) else period, null)
    }

    /** s에 'N월'이 있을 때: 그달, 또는 뒤에 'N일'이 있으면 그날. (기간, 단위, 다음 조각) */
    private fun monthDay(ps: List<P>, s: Int, y: Int): Triple<Period, Grain, Int>? {
        val m = ps[s].n
        val d = ps.getOrNull(s + 2)
        if (d != null && d.k == K.NUM && unit(ps, s + 3, "일") != null && at(ps, s + 4, K.AGO) == null) {
            val day = runCatching { LocalDate.of(y, m, d.n) }.getOrNull() ?: return null
            return Triple(Period(day, day), Grain.DAY, s + 4)
        }
        return Triple(Period.months(y, m), Grain.MONTH, s + 2)
    }

    private fun week(d: LocalDate): Period {
        val mon = d.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
        return Period(mon, mon.plusDays(6))
    }

    /** 올여름·이번 겨울: 올해의 그 계절. 겨울은 1·2월이면 지난 12월에 시작한 겨울 */
    private fun thisSeason(today: LocalDate, s: Int) =
        Period.season(if (s == 3 && today.monthValue <= 2) today.year - 1 else today.year, s)

    /** 지난여름·지난겨울: 오늘 전에 끝난 가장 최근의 그 계절 */
    private fun lastSeason(today: LocalDate, s: Int): Period {
        var y = today.year
        while (!Period.season(y, s).end.isBefore(today)) y--
        return Period.season(y, s)
    }

    private fun age(ps: List<P>, s: Int, words: List<String>, isPerson: (Int) -> Boolean, filler: Set<String>): Hit? {
        val p = ps[s]
        val i: Int
        val kind: String; var n = 0
        when {
            p.k == K.NUM && unit(ps, s + 1, "살", "세") != null -> { kind = "살"; n = p.n; i = s + 2 }
            p.k == K.NUM && unit(ps, s + 1, "개월") != null && at(ps, s + 2, K.AGO) == null -> { kind = "개월"; n = p.n; i = s + 2 }
            p.k == K.AGE_WORD -> { kind = when (p.s) { "돌", "첫돌" -> "돌"; "백일" -> "백일"; else -> "아기" }; i = s + 1 }
            p.k == K.SCHOOL -> { kind = listOf("유치원", "초등", "중등", "고등")[p.n]; i = s + 1 }
            else -> return null
        }
        if (kind == "살" && n > 120) return null
        val t = tail(ps, i) ?: return null
        val tok0 = p.tok; val tokN = ps[t.end - 1].tok
        val personBefore = tok0 > 0 && isPerson(tok0 - 1)
        val atEnd = (tokN + 1 until words.size).all { words[it] in filler }
        val ok = t.mark || when (kind) {
            "살", "개월" -> personBefore || atEnd
            "돌", "백일" -> personBefore
            else -> false // 아기·학교는 '때'가 있어야
        }
        return if (ok) hit(ps, s, t, words, null, Age(kind, n, t.approx)) else null
    }
}
