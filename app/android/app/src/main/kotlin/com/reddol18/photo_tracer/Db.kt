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
 *            fake: 실사 아닌 이미지(1 화면 캡처, 2 만든 이미지, 0 실사, NULL 아직) — Fake.kt, fake_cap/fake_person: 그 점수
 *   vectors  SigLIP 사진 벡터(768). 대표 사진과 구간 밖 사진만
 *   faces    얼굴 위치(사진 대비 0~1)와 SFace 벡터(128), person: 자동 묶음 번호(고를 때 참고), manual: 묶음에서 뺀 얼굴
 *            who/who_sim: 등록한 인물로 찾음(정답 얼굴과 최대 유사도), maybe: 확인이 필요한 인물
 *   people     등록한 인물: 이름(또는 호칭), 관계, 생년(사진 속 나이 계산). 폰 밖으로 나가지 않는다
 *   face_marks 사용자 표시: 얼굴이 그 인물의 정답(ok=1)인지 아닌지(ok=0). person=-1(Who.NOBODY): 아무에게도 붙이지 않음
 *   segments 구간 시작·끝·장 수 (스캔할 때마다 다시 만든다)
 *   runs     밤 작업 기록 (언제, 몇 장, 장당 시간, 쉼, 온도, 왜 멈췄나)
 */
class Db private constructor(ctx: Context) : SQLiteOpenHelper(ctx, "photo_tracer.db", null, 7) {
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

        /** 구간 밖(찍은 날을 모르거나 화면 캡처) 사진과 대표 사진만 장면 벡터를 만든다.
         *  카메라 정보 없는 사진도 — 실사 아닌 이미지 판정(Fake)에 쓴다 */
        const val NEEDS_VECTOR = "(p.segment IS NULL OR p.is_rep = 1 OR p.date_source != '카메라')"
    }

    init {
        setWriteAheadLoggingEnabled(true) // 밤 작업이 쓰는 동안 화면이 읽을 수 있게
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""CREATE TABLE photos (
            id INTEGER PRIMARY KEY, name TEXT, path TEXT, mime TEXT, w INTEGER, h INTEGER,
            taken_at INTEGER, date_source TEXT NOT NULL, received_at INTEGER, lat REAL, lon REAL,
            segment INTEGER, is_rep INTEGER NOT NULL DEFAULT 0,
            faces_done INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0,
            fake INTEGER, fake_cap REAL, fake_person REAL)""")
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
        if (old in 3..4) {
            // 예전 '아님' 표시도 '아무도 아님'으로 (Who.NOBODY): 2등 인물로 넘어가 붙어 있던 것을 뗀다
            db.execSQL("""INSERT OR IGNORE INTO face_marks(face_id, person, ok)
                SELECT DISTINCT face_id, ${Who.NOBODY}, 0 FROM face_marks
                WHERE ok = 0 AND face_id NOT IN (SELECT face_id FROM face_marks WHERE ok = 1)""")
            db.execSQL("""UPDATE faces SET who = NULL, who_sim = NULL, maybe = NULL
                WHERE id IN (SELECT face_id FROM face_marks WHERE person = ${Who.NOBODY})""")
        }
        if (old < 6) db.execSQL("ALTER TABLE photos ADD COLUMN fake INTEGER")
        if (old < 7) { // 6에는 판정 결과만 있었다. 점수를 저장해 문턱만 바꿔 다시 적용할 수 있게
            db.execSQL("ALTER TABLE photos ADD COLUMN fake_cap REAL")
            db.execSQL("ALTER TABLE photos ADD COLUMN fake_person REAL")
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
