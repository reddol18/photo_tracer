package com.reddol18.photo_tracer

import android.content.Context

/**
 * 홈 화면용: 시간 구간(segments)을 '순간'으로 보여 준다. 구간은 갤러리를 읽자마자 생기므로 밤 정리 전에도 볼 수 있다.
 * 인물을 고르면 그 인물이 나온 순간만, 표지도 그 인물 사진으로.
 * 그리고 '이 사람 맞나요?' 확인 목록(확인 필요 얼굴)을 준다.
 */
class Moments(ctx: Context) {
    private val db = Db.get(ctx)

    companion object {
        /** 인물 ?1의 얼굴: 찾음 또는 직접 고름, '아니에요'라고 한 얼굴은 뺀다 (Who.photos와 같은 기준) */
        private const val MINE = """(f.who = ?1 OR EXISTS (SELECT 1 FROM face_marks m WHERE m.face_id = f.id AND m.person = ?1 AND m.ok = 1))
            AND NOT EXISTS (SELECT 1 FROM face_marks m WHERE m.face_id = f.id AND m.person = ?1 AND m.ok = 0)"""
        const val COVERS = 3
    }

    /**
     * 최근 순간부터 limit개. 각 순간: id, start, end(ms), n(장 수, 인물을 고르면 그 인물 사진 수), covers(사진 id), people(등록 인물 id)
     * span(#17 기간 거르기): 기간과 겹치는 순간만(Span.segmentSql). 걸리면 n·표지·순간 사진도 기간 안 날짜의 사진만이라
     *   해를 넘긴 여행도 '2023년'으로 거르면 2023년 사진만 보인다.
     */
    fun list(offset: Int, limit: Int, person: Long?, span: Span? = null): List<Map<String, Any?>> {
        val rows = ArrayList<LongArray>()
        val sql = when {
            person == null && span == null -> "SELECT id, start, end, n FROM segments ORDER BY start DESC LIMIT $limit OFFSET $offset"
            person == null -> """SELECT id, start, "end", c FROM (SELECT s.id, s.start, s."end",
                (SELECT COUNT(*) FROM photos p WHERE p.segment = s.id AND ${span!!.photoSql("p.")}) c
                FROM segments s WHERE ${span.segmentSql("s.")}) WHERE c > 0 ORDER BY start DESC LIMIT $limit OFFSET $offset"""
            else -> """SELECT s.id, s.start, s.end, COUNT(DISTINCT f.photo_id) FROM segments s
                JOIN photos p ON p.segment = s.id JOIN faces f ON f.photo_id = p.id
                WHERE $MINE${if (span != null) " AND ${span.segmentSql("s.")} AND ${span.photoSql("p.")}" else ""}
                GROUP BY s.id ORDER BY s.start DESC LIMIT $limit OFFSET $offset"""
        }
        db.readableDatabase.rawQuery(sql, if (person == null) null else arrayOf(person.toString())).use {
            while (it.moveToNext()) rows.add(longArrayOf(it.getLong(0), it.getLong(1), it.getLong(2), it.getLong(3)))
        }
        return rows.map { (id, start, end, n) ->
            mapOf("id" to id, "start" to start, "end" to end, "n" to n.toInt(), "covers" to photos(id, person, COVERS, span), "people" to people(id))
        }
    }

    /** 사진이 있는 해와 그해 사진 수(#17 기간 시트), 최근 해부터. 날짜는 Span과 같은 기준(찍은 날, 없으면 받은 날), 폰의 시간대로 */
    fun years(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        db.readableDatabase.rawQuery("""SELECT CAST(strftime('%Y', COALESCE(taken_at, received_at) / 1000, 'unixepoch', 'localtime') AS INTEGER) y, COUNT(*)
                FROM photos WHERE COALESCE(taken_at, received_at) IS NOT NULL GROUP BY y ORDER BY y DESC""", null).use {
            while (it.moveToNext()) if (!it.isNull(0)) out.add(mapOf("year" to it.getInt(0), "n" to it.getInt(1)))
        }
        return out
    }

    /** 순간의 사진. 인물을 주면 그 인물이 나온 사진만. limit을 주면 표지용(실사 아닌 이미지는 뒤로, 대표 사진 먼저). span: 기간 안 날짜의 사진만 */
    fun photos(segment: Long, person: Long?, limit: Int? = null, span: Span? = null): List<Long> {
        val lim = if (limit == null) "" else "LIMIT $limit"
        val inSpan = if (span == null) "" else "AND ${span.photoSql("p.")}"
        val (sql, args) = if (person == null)
            "SELECT id FROM photos p WHERE segment = ?1 $inSpan ORDER BY ${if (limit != null) "COALESCE(fake, 0) > 0, is_rep DESC," else ""} taken_at $lim" to
                arrayOf(segment.toString())
        else
            """SELECT DISTINCT p.id FROM photos p JOIN faces f ON f.photo_id = p.id
               WHERE p.segment = ?2 AND $MINE $inSpan ORDER BY p.taken_at $lim""" to arrayOf(person.toString(), segment.toString())
        val out = ArrayList<Long>()
        db.readableDatabase.rawQuery(sql, args).use { while (it.moveToNext()) out.add(it.getLong(0)) }
        if (limit != null && person == null) out.sortBy { id -> taken(id) } // 표지는 고른 뒤 찍은 순서로
        return out
    }

    private fun taken(id: Long): Long =
        db.readableDatabase.rawQuery("SELECT COALESCE(taken_at, 0) FROM photos WHERE id = ?", arrayOf(id.toString()))
            .use { if (it.moveToFirst()) it.getLong(0) else 0L }

    /** 순간에 나온 등록 인물, 많이 나온 순으로 4명까지 */
    private fun people(segment: Long): List<Long> {
        val out = ArrayList<Long>()
        db.readableDatabase.rawQuery("""SELECT f.who, COUNT(*) c FROM faces f JOIN photos p ON p.id = f.photo_id
                WHERE p.segment = ? AND f.who IS NOT NULL GROUP BY f.who ORDER BY c DESC LIMIT 4""", arrayOf(segment.toString())).use {
            while (it.moveToNext()) out.add(it.getLong(0))
        }
        return out
    }

    /**
     * '이 사람 맞나요?' 목록: 등록 인물과 닮았지만 확실하지 않은 얼굴(확인 필요), 닮은 정도가 높은 것부터.
     * 사용자가 이미 맞다·아니다 한 얼굴과 실사 아닌 이미지는 뺀다. total은 전체 수, items는 앞에서 limit개.
     */
    fun review(limit: Int): Map<String, Any?> {
        val where = """FROM faces f JOIN photos p ON p.id = f.photo_id
            WHERE f.maybe IS NOT NULL AND f.who IS NULL AND COALESCE(p.fake, 0) = 0
              AND NOT EXISTS (SELECT 1 FROM face_marks m WHERE m.face_id = f.id)"""
        val total = db.count("SELECT COUNT(*) $where")
        val items = ArrayList<Map<String, Any?>>()
        db.readableDatabase.rawQuery("""SELECT f.id, f.photo_id, f.maybe, f.who_sim, f.x, f.y, f.w, f.h, p.taken_at
                $where ORDER BY f.who_sim DESC LIMIT $limit""", null).use {
            while (it.moveToNext()) items.add(mapOf("face" to it.getLong(0), "photo" to it.getLong(1), "person" to it.getLong(2),
                "sim" to it.getDouble(3), "x" to it.getDouble(4), "y" to it.getDouble(5), "w" to it.getDouble(6), "h" to it.getDouble(7),
                "taken" to (if (it.isNull(8)) null else it.getLong(8))))
        }
        return mapOf("total" to total, "items" to items)
    }
}
