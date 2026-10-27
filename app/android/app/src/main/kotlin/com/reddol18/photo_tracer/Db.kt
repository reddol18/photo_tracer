package com.reddol18.photo_tracer

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 앱 DB. 사진 원본·얼굴 사진은 저장하지 않는다 — 사진은 MediaStore ID로 가리키고, 분석 결과(벡터)만 둔다.
 *   photos   갤러리 사진. taken_at+date_source(찍은 날과 그 근거), received_at(받은 날, 대량 이동한 날은 비움)
 *            segment: 시간 구간 번호(찍은 날을 아는 사진만), is_rep: 구간 대표 사진
 *   vectors  SigLIP 사진 벡터(768). 대표 사진과 구간 밖 사진만
 *   faces    얼굴 위치(사진 대비 0~1)와 SFace 벡터(128), person: 자동 묶음 번호(고를 때 참고), manual: 묶음에서 뺀 얼굴
 *            who/who_sim: 등록한 인물로 찾음(정답 얼굴과 최대 유사도), maybe: 확인이 필요한 인물
 *   people     등록한 인물: 이름(또는 호칭), 관계, 생년(사진 속 나이 계산). 폰 밖으로 나가지 않는다
 *   face_marks 사용자 표시: 얼굴이 그 인물의 정답(ok=1)인지 아닌지(ok=0)
 *   segments 구간 시작·끝·장 수 (스캔할 때마다 다시 만든다)
 *   runs     밤 작업 기록 (언제, 몇 장, 장당 시간, 쉼, 온도, 왜 멈췄나)
 */
class Db private constructor(ctx: Context) : SQLiteOpenHelper(ctx, "photo_tracer.db", null, 4) {
    companion object {
        @Volatile private var instance: Db? = null
        fun get(ctx: Context): Db = instance ?: synchronized(this) {
            instance ?: Db(ctx.applicationContext).also { instance = it }
        }

        fun blob(v: FloatArray): ByteArray =
            ByteBuffer.allocate(v.size * 4).order(ByteOrder.LITTLE_ENDIAN).apply { v.forEach { putFloat(it) } }.array()

        fun floats(b: ByteArray): FloatArray {
            val buf = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN)
            return FloatArray(b.size / 4) { buf.getFloat() }
        }

        /** 구간 밖(찍은 날을 모르거나 화면 캡처) 사진과 대표 사진만 장면 벡터를 만든다 */
        const val NEEDS_VECTOR = "(p.segment IS NULL OR p.is_rep = 1)"
    }

    init {
        setWriteAheadLoggingEnabled(true) // 밤 작업이 쓰는 동안 화면이 읽을 수 있게
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""CREATE TABLE photos (
            id INTEGER PRIMARY KEY, name TEXT, path TEXT, mime TEXT, w INTEGER, h INTEGER,
            taken_at INTEGER, date_source TEXT NOT NULL, received_at INTEGER, lat REAL, lon REAL,
            segment INTEGER, is_rep INTEGER NOT NULL DEFAULT 0,
            faces_done INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0)""")
        db.execSQL("CREATE TABLE vectors (photo_id INTEGER PRIMARY KEY, v BLOB NOT NULL)")
        db.execSQL("""CREATE TABLE faces (id INTEGER PRIMARY KEY AUTOINCREMENT, photo_id INTEGER NOT NULL,
            x REAL, y REAL, w REAL, h REAL, v BLOB NOT NULL, person INTEGER, manual INTEGER NOT NULL DEFAULT 0)""")
        createPeople(db)
        db.execSQL("CREATE TABLE segments (id INTEGER PRIMARY KEY, start INTEGER, end INTEGER, n INTEGER)")
        db.execSQL("""CREATE TABLE runs (id INTEGER PRIMARY KEY AUTOINCREMENT, mode TEXT, start INTEGER, last INTEGER,
            end INTEGER, photos INTEGER DEFAULT 0, faces INTEGER DEFAULT 0, vectors INTEGER DEFAULT 0,
            face_ms REAL, vec_ms REAL, rests INTEGER DEFAULT 0, max_temp REAL, stop TEXT, note TEXT)""")
        db.execSQL("CREATE INDEX faces_photo ON faces(photo_id)")
        db.execSQL("CREATE INDEX faces_person ON faces(person)")
        db.execSQL("CREATE INDEX photos_segment ON photos(segment)")
    }

    override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) {
        if (old < 2) db.execSQL("ALTER TABLE faces ADD COLUMN manual INTEGER NOT NULL DEFAULT 0")
        if (old < 3) createPeople(db)
        if (old == 3) {
            db.execSQL("ALTER TABLE people ADD COLUMN relation TEXT")
            db.execSQL("ALTER TABLE people ADD COLUMN birth_year INTEGER")
        }
    }

    private fun createPeople(db: SQLiteDatabase) {
        db.execSQL("ALTER TABLE faces ADD COLUMN who INTEGER")
        db.execSQL("ALTER TABLE faces ADD COLUMN who_sim REAL")
        db.execSQL("ALTER TABLE faces ADD COLUMN maybe INTEGER")
        db.execSQL("CREATE INDEX faces_who ON faces(who)")
        db.execSQL("CREATE INDEX faces_maybe ON faces(maybe)")
        db.execSQL("CREATE TABLE people (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, relation TEXT, birth_year INTEGER)")
        db.execSQL("CREATE TABLE face_marks (face_id INTEGER NOT NULL, person INTEGER NOT NULL, ok INTEGER NOT NULL, PRIMARY KEY (face_id, person))")
    }

    fun count(sql: String, vararg args: String): Int =
        readableDatabase.rawQuery(sql, args).use { if (it.moveToFirst()) it.getInt(0) else 0 }
}
