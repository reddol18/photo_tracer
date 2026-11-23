package com.reddol18.photo_tracer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.util.Size

/**
 * 썸네일 공용 읽기 (#26). 29 이상은 loadThumbnail(MediaStore 캐시), 28은 그 API가 없어 원본을 ImageDecoder로 줄여 읽는다.
 * 두 길 모두 회전(EXIF orientation)이 반영된 비트맵이고 긴 변이 size 언저리다 — 얼굴 좌표(회전 반영 이미지 기준 비율)가 그대로 맞는다.
 * 호출부가 픽셀을 읽거나(getPixels) 자르거나 compress하므로 하드웨어 비트맵이면 안 된다(loadThumbnail도 소프트웨어로 준다).
 */
object Thumbs {
    fun load(ctx: Context, uri: Uri, size: Int): Bitmap =
        if (Build.VERSION.SDK_INT >= 29) ctx.contentResolver.loadThumbnail(uri, Size(size, size), null)
        else decode(ctx, uri, size) // 28: 원본 디코드라 29보다 느리다(S8에서 확인 필요)

    /** 원본을 긴 변 max px 이하로 줄여 읽는다(비율 유지, 회전 반영, 키우지 않음) */
    fun decode(ctx: Context, uri: Uri, max: Int): Bitmap =
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ctx.contentResolver, uri)) { dec, info, _ ->
            val w = info.size.width
            val h = info.size.height
            val s = max.toDouble() / maxOf(w, h)
            if (s < 1) dec.setTargetSize((w * s).toInt().coerceAtLeast(1), (h * s).toInt().coerceAtLeast(1))
            dec.allocator = ImageDecoder.ALLOCATOR_SOFTWARE // compress·getPixels하려면 소프트웨어 비트맵이어야 한다
        }
}
