package com.reddol18.phototracer.bench_app

import android.content.ContentUris
import android.content.Context
import android.media.ExifInterface
import android.provider.MediaStore
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 0단계 구간(이벤트) 나누기 검증용. 갤러리 사진의 메타데이터만 읽어 bench/meta_<ms>.json 으로 쓴다.
 * 사진 픽셀은 읽지 않는다. 날짜 출처 확인을 위해 MediaStore 날짜와 EXIF 촬영 시각을 함께 남긴다.
 * GPS는 구간 경계(수 km 단위) 판단에만 쓰므로 소수 셋째 자리(약 100m)로 줄여 저장한다.
 */
class MetaScan(private val ctx: Context) {
    fun run(): String {
        val t0 = System.currentTimeMillis()
        val cols = arrayOf(
            MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH, MediaStore.Images.Media.MIME_TYPE,
            MediaStore.Images.Media.DATE_TAKEN, MediaStore.Images.Media.DATE_ADDED,
            MediaStore.Images.Media.DATE_MODIFIED, MediaStore.Images.Media.WIDTH,
            MediaStore.Images.Media.HEIGHT, MediaStore.Images.Media.SIZE,
        )
        val rows = JSONArray()
        var exifFail = 0
        ctx.contentResolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cols, null, null,
                                  "${MediaStore.Images.Media.DATE_TAKEN} DESC")?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val row = JSONObject()
                    .put("id", id).put("name", c.getString(1)).put("path", c.getString(2))
                    .put("mime", c.getString(3))
                    .put("date_taken", if (c.isNull(4)) JSONObject.NULL else c.getLong(4))
                    .put("date_added", c.getLong(5) * 1000).put("date_modified", c.getLong(6) * 1000)
                    .put("w", c.getInt(7)).put("h", c.getInt(8)).put("size", c.getLong(9))
                try {
                    // 위치 정보는 원본을 요청해야 가려지지 않는다(ACCESS_MEDIA_LOCATION)
                    val uri = MediaStore.setRequireOriginal(
                        ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id))
                    ctx.contentResolver.openInputStream(uri)?.use { s ->
                        val exif = ExifInterface(s)
                        exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)?.let { row.put("exif_dt", it) }
                        exif.getAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL)?.let { row.put("exif_tz", it) }
                        exif.getAttribute(ExifInterface.TAG_MAKE)?.let { row.put("make", it) }
                        val ll = FloatArray(2)
                        if (exif.getLatLong(ll)) {
                            row.put("lat", Math.round(ll[0] * 1000.0) / 1000.0)
                                .put("lon", Math.round(ll[1] * 1000.0) / 1000.0)
                        }
                    }
                } catch (e: Exception) {
                    exifFail++
                    row.put("exif_error", e.javaClass.simpleName)
                }
                rows.put(row)
                if (rows.length() % 500 == 0) Log.i("Bench", "메타 스캔 ${rows.length()}장")
            }
        }
        val out = File(Benchmark.benchDir(ctx), "meta_${System.currentTimeMillis()}.json")
        out.writeText(JSONObject().put("count", rows.length()).put("exif_fail", exifFail)
            .put("scan_ms", System.currentTimeMillis() - t0).put("photos", rows).toString())
        out.setReadable(true, false)
        Log.i("Bench", "메타 스캔 완료: ${rows.length()}장, EXIF 실패 $exifFail, ${out.absolutePath}")
        return out.absolutePath
    }
}
