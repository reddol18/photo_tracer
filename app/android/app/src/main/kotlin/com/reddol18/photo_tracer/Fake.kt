package com.reddol18.photo_tracer

import android.content.Context
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 실사가 아닌 이미지 판정: 화면 캡처, AI로 만든 인물 그림(아바타 앱), 연예인·광고 사진. 이런 사진 속 얼굴은 인물 추측에서 뺀다.
 * photos.fake: NULL 아직 안 봄, 0 실사, 1 화면 캡처, 2 만든 이미지.
 *   카메라 정보 있음 → 실사. 없으면 벡터가 있을 때 점수로만 판정한다:
 *   화면 캡처 = SigLIP 캡처 점수 > CAPTURE,  만든 이미지 = SigLIP 인물 점수 > PERSON
 *   벡터가 아직 없으면 스크린샷 폴더 · PNG 를 화면 캡처로 둔다(밤 작업이 벡터를 만들면 다시 본다).
 *   폴더만으로 정하지 않는 까닭: 스크린샷 폴더·PNG에 아이 동영상을 멈춰 찍은 장면이 많고, 동영상 장면 캡처(Videocaptures)도 실사다.
 * 점수 = (그쪽 문구들과의 최대 코사인) - (실사 문구들과의 최대 코사인). 문구 벡터는 assets/search/fake.bin (poc/app_assets.py fake).
 * 점수는 photos.fake_cap / fake_person 에 한 번만 계산해 두고, 문턱은 판정할 때마다 SQL로 다시 적용한다(문턱만 바꿔도 된다).
 * 카메라로 찍은 사진(date_source '카메라')은 점수와 상관없이 실사로 둔다 — 캐릭터 전시장·그림 그리는 아이 사진이 점수가 높게 나온다.
 * 문턱은 폰 점수로 고른다: 카메라 정보 없는 사진의 점수를 앱 폴더 fake_scores.csv(id, 점수만)로 내보내 PC에서 썸네일과 맞춰 본다
 * (poc/artificial_phone.py). PC 썸네일 점수와 폰 점수는 차이가 커서(채팅으로 받은 사진은 폰이 더 높다) PC 문턱을 그대로 못 쓴다.
 */
class Fake(private val ctx: Context) {
    companion object {
        // 폰 점수 7024장 접촉 시트(poc/artificial_phone.py)로 고름:
        //   캡처 > 0 은 1164위(+0.001)까지 모두 화면·광고·쇼핑 화면, 0 아래부터 CCTV·고양이·아이 영상 장면이 섞인다
        //   인물 > 0.005 는 AI 아바타·AI 고양이·연예인 사진, +0.007 근처 64장에 실사 1장, +0.002 근처엔 5장
        const val CAPTURE = 0.0f
        const val PERSON = 0.005f
        private const val N_REAL = 6
        private const val N_CAPTURE = 3
    }

    private val db = Db.get(ctx)
    private val prompts: List<FloatArray> by lazy {
        ctx.assets.open("search/fake.bin").use { s ->
            val b = ByteBuffer.wrap(s.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
            List(b.remaining() / 4 / 768) { FloatArray(768) { b.getFloat() } }
        }
    }

    private fun dot(a: FloatArray, b: FloatArray): Float { var s = 0f; for (d in a.indices) s += a[d] * b[d]; return s }

    /** 점수가 없는 사진(카메라 정보 없음 + 벡터 있음)의 점수를 매기고, 모든 사진에 문턱을 다시 적용한다 */
    fun judgeNew() {
        val todo = ArrayList<Pair<Long, FloatArray>>()
        db.readableDatabase.rawQuery("""SELECT p.id, v.v FROM photos p JOIN vectors v ON v.photo_id = p.id
                WHERE p.date_source != '카메라' AND p.fake_cap IS NULL""", null).use {
            while (it.moveToNext()) todo.add(it.getLong(0) to Db.floats(it.getBlob(1)))
        }
        val w = db.writableDatabase
        w.beginTransaction()
        try {
            for ((id, v) in todo) {
                val real = (0 until N_REAL).maxOf { dot(v, prompts[it]) }
                val capture = (N_REAL until N_REAL + N_CAPTURE).maxOf { dot(v, prompts[it]) } - real
                val person = (N_REAL + N_CAPTURE until prompts.size).maxOf { dot(v, prompts[it]) } - real
                w.execSQL("UPDATE photos SET fake_cap = ?, fake_person = ? WHERE id = ?", arrayOf<Any>(capture, person, id))
            }
            w.execSQL("""UPDATE photos SET fake = CASE
                WHEN date_source = '카메라' THEN 0
                WHEN fake_cap > ? THEN 1
                WHEN fake_person > ? THEN 2
                WHEN fake_cap IS NOT NULL THEN 0 -- 점수가 있으면 점수로만: 아이 동영상을 멈춰 찍은 스크린샷은 실사로 둔다
                WHEN path LIKE 'DCIM/Screenshots%' OR mime = 'image/png' THEN 1 -- 벡터가 아직 없을 때만 폴더·PNG로
                ELSE 0 END""", arrayOf<Any>(CAPTURE, PERSON))
            w.setTransactionSuccessful()
        } finally { w.endTransaction() }
        if (todo.isNotEmpty()) export()
    }

    /** 문턱 고르기용: 카메라 정보 없는 사진의 id·점수만 앱 폴더에 (사진·이름은 안 쓴다) */
    private fun export() {
        val dir = ctx.getExternalFilesDir(null) ?: return
        File(dir, "fake_scores.csv").bufferedWriter().use { out ->
            out.write("id,cap,person\n")
            db.readableDatabase.rawQuery("SELECT id, fake_cap, fake_person FROM photos WHERE fake_cap IS NOT NULL", null).use {
                while (it.moveToNext()) out.write("${it.getLong(0)},${it.getFloat(1)},${it.getFloat(2)}\n")
            }
        }
    }
}
