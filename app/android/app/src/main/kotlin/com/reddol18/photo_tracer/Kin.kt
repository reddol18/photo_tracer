package com.reddol18.photo_tracer

/**
 * 관계 낱말 표(#5). 등록할 때 적는 관계는 사용자 기준이다("엄마" = 사용자의 어머니, "아내" = 아이의 엄마).
 * SAME: 같은 뜻의 다른 말 → 대표 말. 등록한 관계("큰딸", "어머님")도 canon으로 대표 말에 맞춘다.
 * FROM[다른 인물의 관계][이 낱말] = 사용자 기준 관계 후보(앞이 먼저). 검색어에 다른 인물이 함께 있을 때
 *   그 인물 입장에서 부른 말로 풀어 본다. 예: "딸과 엄마" → 딸 입장의 엄마 = 아내(사용자가 엄마라면 나).
 *   사용자의 성별을 모르니 양쪽을 다 후보로 두고, 등록한 인물이 있는 쪽만 남는다.
 */
object Kin {
    val SAME: Map<String, String> = buildMap {
        // 이름을 put으로 하면 안의 put이 자기 자신을 불러 끝없이 돈다(폰에서 StackOverflowError로 확인)
        fun same(main: String, vararg alt: String) { this[main] = main; alt.forEach { this[it] = main } }
        same("나", "본인", "저")
        same("아내", "와이프", "부인", "집사람", "마누라", "안사람")
        same("남편", "신랑", "바깥사람")
        same("딸", "따님", "딸내미")
        same("아들", "아드님")
        same("엄마", "어머니", "어머님", "모친")
        same("아빠", "아버지", "아버님", "부친")
        same("할머니", "할매", "외할머니", "친할머니")
        same("할아버지", "할배", "외할아버지", "친할아버지")
        same("장모", "장모님")
        same("장인", "장인어른")
        same("시어머니", "시어머님")
        same("시아버지", "시아버님")
        same("손녀"); same("손자")
        same("며느리"); same("사위")
        same("언니"); same("누나"); same("오빠"); same("형"); same("동생")
    }

    /** 등록한 관계를 대표 말로: 그대로 있거나, 끝이 표의 말이면("큰딸" → 딸) 그 말. 없으면 그대로 */
    fun canon(rel: String): String =
        SAME[rel] ?: SAME.keys.filter { it.length >= 2 || rel.length <= 3 }.filter { rel.endsWith(it) }.maxByOrNull { it.length }?.let { SAME[it] } ?: rel

    private val CHILD = mapOf(
        "엄마" to listOf("아내", "나"), "아빠" to listOf("남편", "나"),
        "할머니" to listOf("엄마", "장모", "시어머니"), "할아버지" to listOf("아빠", "장인", "시아버지"),
        "언니" to listOf("딸"), "누나" to listOf("딸"), "오빠" to listOf("아들"), "형" to listOf("아들"), "동생" to listOf("딸", "아들"))
    private val SPOUSE = mapOf(
        "엄마" to listOf("장모", "시어머니"), "아빠" to listOf("장인", "시아버지"), "딸" to listOf("딸"), "아들" to listOf("아들"))
    private val PARENT = mapOf(
        "딸" to listOf("나"), "아들" to listOf("나"), "손녀" to listOf("딸"), "손자" to listOf("아들"),
        "며느리" to listOf("아내"), "사위" to listOf("남편"))

    /**
     * 입장 풀이의 기준이 될 수 있는 정도: 아래 세대일수록 높다(가족 사진은 아이가 가운데라 "딸과 엄마"는 딸 입장으로 말하기 쉽다).
     * 낱말이 이미 등록한 관계로 바로 맞으면, 그보다 높은 관계 입장으로만 다시 푼다.
     *   그래서 "딸과 엄마"에서 엄마는 딸 입장(아내)으로 풀지만, 딸은 엄마 입장(나)으로 풀지 않는다(폰에서 딸이 '나'로 잡혔다).
     */
    fun rank(kin: String?): Int = when (kin) { "딸", "아들" -> 3; "아내", "남편" -> 2; "엄마", "아빠" -> 1; else -> 0 }

    val FROM: Map<String, Map<String, List<String>>> = mapOf(
        "딸" to CHILD, "아들" to CHILD, "아내" to SPOUSE, "남편" to SPOUSE,
        "엄마" to PARENT + mapOf("남편" to listOf("아빠")), "아빠" to PARENT + mapOf("아내" to listOf("엄마")))

    // 말이 가리키는 사람의 성별(#10)
    private val FEMALE = setOf("엄마", "딸", "할머니", "언니", "누나", "손녀", "며느리", "아내", "장모", "시어머니")
    private val MALE = setOf("아빠", "아들", "할아버지", "오빠", "형", "손자", "사위", "남편", "장인", "시아버지")
    // 사용자 기준 관계 중 사용자가 남자여야(아내 쪽 가족) / 여자여야(남편 쪽 가족) 있는 것
    private val IF_MALE = setOf("아내", "장모", "장인")
    private val IF_FEMALE = setOf("남편", "시어머니", "시아버지")

    /**
     * 사용자 성별("남"/"여", 모르면 null)로 입장 풀이 후보를 거른다(#10): word를 사용자 기준 관계 target으로 풀어도 되나.
     *   target이 '나'면 word가 가리키는 성별이 사용자와 같아야 한다(남자에게 엄마 입장의 딸은 내가 아니다).
     *   아내·장모·장인은 남자, 남편·시어머니·시아버지는 여자일 때만.
     */
    fun fits(gender: String?, word: String, target: String): Boolean = when {
        gender == null -> true
        target == "나" -> !(gender == "남" && word in FEMALE) && !(gender == "여" && word in MALE)
        target in IF_MALE -> gender == "남"
        target in IF_FEMALE -> gender == "여"
        else -> true
    }
}
