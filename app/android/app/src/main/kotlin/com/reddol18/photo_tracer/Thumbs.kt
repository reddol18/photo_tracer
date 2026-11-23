package com.reddol18.photo_tracer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import android.os.Build
import android.util.Log
import android.util.Size
import androidx.exifinterface.media.ExifInterface
import java.io.IOException

/**
 * 썸네일 공용 읽기 (#26). 29 이상은 loadThumbnail(MediaStore 캐시), 28은 그 API가 없어 원본을 줄여 읽는다.
 * 두 길 모두 회전(EXIF orientation)이 반영된 비트맵이고 긴 변이 size 언저리다 — 얼굴 좌표(회전 반영 이미지 기준 비율)가 그대로 맞는다.
 * 호출부가 픽셀을 읽거나(getPixels) 자르거나 compress하므로 하드웨어 비트맵이면 안 된다(loadThumbnail도 소프트웨어로 준다).
 */
object Thumbs {
    private const val TAG = "PhotoTracer"

    fun load(ctx: Context, uri: Uri, size: Int): Bitmap =
        if (Build.VERSION.SDK_INT >= 29) ctx.contentResolver.loadThumbnail(uri, Size(size, size), null)
        else decode(ctx, uri, size) // 28: BitmapFactory 표본 디코드(안 되면 ImageDecoder로 물러섬)

    /**
     * 원본을 긴 변 max px 이하로 줄여 읽는다(비율 유지, 회전 반영, 키우지 않음, 소프트웨어 ARGB_8888).
     *  - 29 이상: 지금까지처럼 ImageDecoder setTargetSize(크게 보기 동작 그대로).
     *  - 28: Android 9의 ImageDecoder는 일반 카메라 JPEG에서도 setTargetSize·setTargetSampleSize가
     *    "getPixels failed with error invalid scale"로 실패해(S8 확인) 원본 전체 디코드로만 읽혔다 — 그래서 BitmapFactory 표본 디코드를 먼저 쓴다.
     *  - BitmapFactory가 안 되면(HEIC 등) ImageDecoder 1→2→3차로 물러선다.
     * 실패 로그에는 형식(mime)과 원본 크기만 남긴다(파일 이름·경로 금지).
     */
    fun decode(ctx: Context, uri: Uri, max: Int): Bitmap {
        val mime = ctx.contentResolver.getType(uri)
        if (Build.VERSION.SDK_INT >= 29) {
            decodeTargetSize(ctx, uri, max, mime)?.let { return it }
            factoryDecode(ctx, uri, max, mime)?.let { return it }
            return decodeFallback(ctx, uri, max, mime)
        }
        factoryDecode(ctx, uri, max, mime)?.let { return it }
        decodeTargetSize(ctx, uri, max, mime)?.let { return it }
        return decodeFallback(ctx, uri, max, mime)
    }

    /** ImageDecoder 1차: 정확한 대상 크기. 실패하면 null */
    private fun decodeTargetSize(ctx: Context, uri: Uri, max: Int, mime: String?): Bitmap? {
        var origW = 0
        var origH = 0
        return try {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(ctx.contentResolver, uri)) { dec, info, _ ->
                origW = info.size.width
                origH = info.size.height
                val s = max.toDouble() / maxOf(origW, origH)
                if (s < 1) dec.setTargetSize((origW * s).toInt().coerceAtLeast(1), (origH * s).toInt().coerceAtLeast(1))
                dec.allocator = ImageDecoder.ALLOCATOR_SOFTWARE // compress·getPixels하려면 소프트웨어 비트맵이어야 한다
            }
        } catch (e: IOException) {
            Log.w(TAG, "decode ImageDecoder 1차(setTargetSize) 실패: mime=$mime size=${origW}x$origH — ${e.message}")
            null
        }
    }

    /** ImageDecoder 2차(2의 거듭제곱 표본 배율) → 3차(원본 전체 디코드 후 축소). 3차 실패는 그대로 던진다 */
    private fun decodeFallback(ctx: Context, uri: Uri, max: Int, mime: String?): Bitmap {
        var origW = 0
        var origH = 0
        try {
            val bmp = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ctx.contentResolver, uri)) { dec, info, _ ->
                origW = info.size.width
                origH = info.size.height
                val sample = sampleSizeFor(maxOf(origW, origH), max)
                if (sample > 1) dec.setTargetSampleSize(sample)
                dec.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
            return fitLongSide(bmp, max)
        } catch (e: IOException) {
            Log.w(TAG, "decode ImageDecoder 2차(setTargetSampleSize) 실패: mime=$mime size=${origW}x$origH — ${e.message}")
        }
        // 3차: 원본 전체를 메모리에 올리므로 무겁다. 앞의 길이 모두 실패할 때만 온다.
        val full = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ctx.contentResolver, uri)) { dec, _, _ ->
            dec.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        return fitLongSide(full, max)
    }

    /**
     * BitmapFactory 표본 디코드: 크기만 읽고 → 2의 거듭제곱 inSampleSize로 읽고 → 긴 변 max로 줄이고 → EXIF 회전·뒤집기 적용.
     * 스트림은 단계마다 새로 연다. 디코드 실패(null)나 예외면 null(호출부가 ImageDecoder로 물러선다).
     */
    private fun factoryDecode(ctx: Context, uri: Uri, max: Int, mime: String?): Bitmap? {
        val cr = ctx.contentResolver
        var origW = 0
        var origH = 0
        var cur: Bitmap? = null
        try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            cr.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            origW = bounds.outWidth
            origH = bounds.outHeight
            if (origW <= 0 || origH <= 0) {
                Log.w(TAG, "decode BitmapFactory 크기 읽기 실패: mime=$mime")
                return null
            }
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sampleSizeFor(maxOf(origW, origH), max)
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            cur = cr.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) }
            if (cur == null) {
                Log.w(TAG, "decode BitmapFactory 디코드 실패(null): mime=$mime size=${origW}x$origH")
                return null
            }
            cur = fitLongSide(cur, max)
            val orientation = cr.openInputStream(uri)?.use {
                ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            } ?: ExifInterface.ORIENTATION_NORMAL
            val out = applyOrientation(cur, orientation)
            cur = null
            return out
        } catch (e: Exception) {
            Log.w(TAG, "decode BitmapFactory 실패: mime=$mime size=${origW}x$origH — ${e.javaClass.simpleName}: ${e.message}")
            cur?.recycle()
            return null
        }
    }

    /** EXIF orientation을 비트맵에 반영한다. 바꿨으면 원래 비트맵은 놓아준다 */
    private fun applyOrientation(bmp: Bitmap, orientation: Int): Bitmap {
        val o = orientOf(orientation)
        if (o.degrees == 0 && !o.flipX) return bmp
        val m = Matrix()
        m.setRotate(o.degrees.toFloat())
        if (o.flipX) m.postScale(-1f, 1f)
        val out = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
        if (out !== bmp) bmp.recycle()
        return out
    }

    /** 회전(시계 방향 도) 뒤 좌우 뒤집기 여부. swapsAxes면 결과의 가로·세로가 원본과 바뀐다 */
    data class Orient(val degrees: Int, val flipX: Boolean) {
        val swapsAxes: Boolean get() = degrees % 180 != 0
    }

    /**
     * EXIF orientation(1~8) → 회전 후 뒤집기. Matrix로는 setRotate(degrees) 뒤 postScale(-1, 1).
     * 알 수 없는 값(0·UNDEFINED 등)은 그대로 둔다. 순수 함수라 단위 테스트한다(ThumbsOrientTest).
     */
    fun orientOf(orientation: Int): Orient = when (orientation) {
        2 -> Orient(0, true)     // FLIP_HORIZONTAL
        3 -> Orient(180, false)  // ROTATE_180
        4 -> Orient(180, true)   // FLIP_VERTICAL = 180° 회전 + 좌우 뒤집기
        5 -> Orient(90, true)    // TRANSPOSE
        6 -> Orient(90, false)   // ROTATE_90
        7 -> Orient(270, true)   // TRANSVERSE
        8 -> Orient(270, false)  // ROTATE_270
        else -> Orient(0, false) // NORMAL·UNDEFINED
    }

    /** 결과 긴 변이 max 이상으로 남는 가장 큰 2의 거듭제곱 표본 배율(최소 1) */
    internal fun sampleSizeFor(longSide: Int, max: Int): Int {
        var s = 1
        while (longSide / (s * 2) >= max) s *= 2
        return s
    }

    /** 긴 변이 max보다 크면 비율을 유지해 max로 줄인다(키우지 않음). 줄였으면 원래 비트맵은 놓아준다 */
    private fun fitLongSide(bmp: Bitmap, max: Int): Bitmap {
        val w = bmp.width
        val h = bmp.height
        val s = max.toDouble() / maxOf(w, h)
        if (s >= 1) return bmp
        val out = Bitmap.createScaledBitmap(bmp, (w * s).toInt().coerceAtLeast(1), (h * s).toInt().coerceAtLeast(1), true)
        if (out !== bmp) bmp.recycle()
        return out
    }
}
