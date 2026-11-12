package com.reddol18.photo_tracer

import android.Manifest
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/** 화면(Flutter)과 엔진(Kotlin) 사이 통로. 무거운 일은 작업 스레드에서 하고 결과만 넘긴다. */
class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val thumbs = Executors.newFixedThreadPool(4)
    private val clusterer = Executors.newSingleThreadExecutor() // 다시 묶는 동안에도 다른 화면 요청이 기다리지 않게
    private val main = Handler(Looper.getMainLooper())
    private var permissionResult: MethodChannel.Result? = null

    private val permissions = buildList {
        add(if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE)
        add(Manifest.permission.ACCESS_MEDIA_LOCATION)
        if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
    private fun photosGranted() = granted(permissions[0])

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val db = Db.get(this)
        // 인물 붙이는 규칙이 바뀐 버전이면 한 번 다시 붙인다 (작업 스레드 첫 일이라 화면 요청보다 먼저 끝난다)
        val prefs = getSharedPreferences("settings", MODE_PRIVATE)
        if (prefs.getInt("who_rule", 0) < Who.RULE) worker.execute {
            Who(this).assignAll()
            prefs.edit().putInt("who_rule", Who.RULE).apply()
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app").setMethodCallHandler { call, result ->
            fun bg(pool: java.util.concurrent.ExecutorService = worker, block: () -> Any?) = pool.execute {
                try {
                    val v = block().takeUnless { it is Unit } // 돌려줄 값이 없는 일(Unit)은 채널이 못 실어 나른다
                    main.post { result.success(v) }
                } catch (e: Throwable) {
                    Log.e("PhotoTracer", "${call.method} 실패", e)
                    main.post { result.error(call.method, e.toString(), null) }
                }
            }
            when (call.method) {
                "status" -> bg { status(db) }
                "requestPermissions" -> {
                    permissionResult = result
                    requestPermissions(permissions.toTypedArray(), 1)
                }
                "openBatterySettings" -> {
                    // 이 앱만 바로 묻는 창. 안 되면 전체 목록으로
                    val direct = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
                    try { startActivity(direct) } catch (e: Exception) {
                        startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    }
                    result.success(null)
                }
                "openAppSettings" -> {
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                    result.success(null)
                }
                "openVendorSettings" -> { openVendorSettings(); result.success(null) }
                "scan" -> {
                    if (photosGranted()) { if (IndexWorker.nightOn(this)) IndexWorker.scheduleNight(this); IndexWorker.scanNow(this) }
                    worker.execute { try { Search(this).debugEval() } catch (e: Exception) { Log.w("PhotoTracer", "search_eval 실패: $e") } }
                    worker.execute { try { Search(this).debugPeople() } catch (e: Exception) { Log.w("PhotoTracer", "people_eval 실패: $e") } }
                    clusterer.execute { try { People(this).debugEval() } catch (e: Exception) { Log.w("PhotoTracer", "cluster_eval 실패: $e") } }
                    clusterer.execute { try { Who(this).debugSmall() } catch (e: Exception) { Log.w("PhotoTracer", "small_eval 실패: $e") } }
                    clusterer.execute { try { Who(this).debugFaceCrops() } catch (e: Exception) { Log.w("PhotoTracer", "face_crops 실패: $e") } }
                    result.success(null)
                }
                "setNight" -> { IndexWorker.setNight(this, call.argument<Boolean>("on") == true); result.success(null) }
                "startNow" -> { IndexWorker.startNow(this); result.success(null) }
                "stopNow" -> { IndexWorker.stopNow(this); result.success(null) }
                // picks: 사용자가 칩에서 바꾼 인물 풀이 {낱말: [인물 id]} (#5)
                "search" -> bg {
                    val picks = call.argument<Map<String, List<Number>>>("picks")?.mapValues { (_, v) -> v.map { it.toLong() } } ?: emptyMap()
                    Search(this).search(call.argument<String>("q") ?: "", picks)
                }
                "searchHintSeen" -> bg { Search(this).hintSeen() }
                "gender" -> bg { Search(this).gender() }
                "setGender" -> bg { Search(this).setGender(call.argument<String>("g")) }
                "segmentPhotos" -> bg {
                    ids(db, "SELECT id FROM photos WHERE segment = ? ORDER BY taken_at", call.argument<Number>("id").toString())
                }
                "persons" -> bg {
                    val out = ArrayList<Map<String, Any>>()
                    // known: 얼굴 절반 이상이 이미 등록한 인물(찾음 또는 정답) — 화면에서 접어 둔다(#6)
                    db.readableDatabase.rawQuery("""SELECT person, COUNT(DISTINCT photo_id) n, MIN(id),
                        AVG(who IS NOT NULL OR EXISTS (SELECT 1 FROM face_marks m WHERE m.face_id = faces.id AND m.ok = 1)) FROM faces
                        WHERE person IS NOT NULL GROUP BY person HAVING COUNT(*) >= ${People.MIN_SHOW} ORDER BY n DESC""", null).use {
                        while (it.moveToNext()) out.add(mapOf("id" to it.getLong(0), "n" to it.getInt(1), "face" to cover(db, it.getLong(0)),
                            "known" to (it.getDouble(3) >= 0.5)))
                    }
                    out
                }
                "personPhotos" -> bg { People(this).photos(call.argument<Number>("id")!!.toLong()) }
                "recluster" -> bg(clusterer) { People(this).full() }
                "clusterInfo" -> bg { People(this).info() }
                // 등록한 인물
                "people" -> bg { Who(this).people() }
                "whoPhotos" -> bg { Who(this).photos(call.argument<Number>("id")!!.toLong()) }
                "whoCreate" -> bg {
                    Who(this).create(call.argument<String>("name")!!, call.argument("relation"), call.argument<Number>("birth_year")?.toInt(),
                        longs(call.argument("faces")))
                }
                "whoUpdate" -> bg {
                    Who(this).update(call.argument<Number>("id")!!.toLong(), call.argument<String>("name")!!, call.argument("relation"),
                        call.argument<Number>("birth_year")?.toInt())
                }
                "whoDelete" -> bg { Who(this).delete(call.argument<Number>("id")!!.toLong()) }
                "whoMark" -> bg { Who(this).mark(call.argument<Number>("id")!!.toLong(), longs(call.argument("faces")), call.argument<Boolean>("ok") == true) }
                "whoConfirm" -> bg { Who(this).confirmPhotos(call.argument<Number>("id")!!.toLong(), longs(call.argument("photos"))) }
                "whoReject" -> bg { Who(this).rejectPhotos(call.argument<Number>("id")!!.toLong(), longs(call.argument("photos"))) }
                // 인물 추측에서 뺀 이미지 (1 화면 캡처, 2 만든 이미지) — 잘못 뺀 게 없나 사람이 보게
                "fakePhotos" -> bg { ids(db, "SELECT id FROM photos WHERE fake = ? ORDER BY COALESCE(taken_at, received_at, 0) DESC",
                    call.argument<Number>("kind").toString()) }
                "fakeCounts" -> bg { (1..2).map { k -> db.count("SELECT COUNT(*) FROM photos WHERE fake = ?", k.toString()) } }
                "whoRejectAll" ->bg { Who(this).rejectAll(call.argument<Number>("photo")!!.toLong()) }
                "whoMerge" ->bg { Who(this).merge(longs(call.argument("ids"))) }
                "thumb" -> bg(thumbs) { thumb(call.argument<Number>("id")!!.toLong(), call.argument<Int>("size") ?: 256) }
                "photo" -> bg(thumbs) { photo(call.argument<Number>("id")!!.toLong(), call.argument<Int>("max") ?: 1600) }
                "faceThumb" -> bg(thumbs) { faceThumb(call.argument<Number>("id")!!.toLong(), call.argument<Int>("size") ?: 160) }
                "photoInfo" -> bg {
                    val id = call.argument<Number>("id").toString()
                    // 얼굴 위치(사진 대비 0~1)와 묶인 인물 — 사진 위에 상자로 그린다
                    val faces = ArrayList<Map<String, Any?>>()
                    db.readableDatabase.rawQuery("SELECT id, x, y, w, h, person, who, maybe, who_sim FROM faces WHERE photo_id = ?", arrayOf(id)).use {
                        val n = { i: Int -> if (it.isNull(i)) null else it.getLong(i) }
                        while (it.moveToNext()) faces.add(mapOf("id" to it.getLong(0), "x" to it.getDouble(1), "y" to it.getDouble(2),
                            "w" to it.getDouble(3), "h" to it.getDouble(4), "person" to n(5), "who" to n(6), "maybe" to n(7),
                            "sim" to (if (it.isNull(8)) null else it.getDouble(8))))
                    }
                    db.readableDatabase.rawQuery("SELECT taken_at, date_source, received_at, name FROM photos WHERE id = ?", arrayOf(id)).use {
                        if (!it.moveToFirst()) null else mapOf("taken" to (if (it.isNull(0)) null else it.getLong(0)),
                            "date_source" to it.getString(1), "received" to (if (it.isNull(2)) null else it.getLong(2)), "faces" to faces)
                    }
                }
                "runs" -> bg {
                    val out = ArrayList<Map<String, Any?>>()
                    db.readableDatabase.rawQuery("SELECT * FROM runs ORDER BY id DESC LIMIT 50", null).use { c ->
                        while (c.moveToNext()) out.add((0 until c.columnCount).associate { i ->
                            c.getColumnName(i) to when (c.getType(i)) {
                                android.database.Cursor.FIELD_TYPE_INTEGER -> c.getLong(i)
                                android.database.Cursor.FIELD_TYPE_FLOAT -> c.getDouble(i)
                                android.database.Cursor.FIELD_TYPE_NULL -> null
                                else -> c.getString(i)
                            }
                        })
                    }
                    out
                }
                "exportQueryVectors" -> bg { Search(this).exportQueryVectors() }
                // 화면 설정(대표 색·화면 모드·처음 안내 봄·최근 검색어): 문자열 하나씩
                "pref" -> bg { getSharedPreferences("ui", MODE_PRIVATE).getString(call.argument<String>("key"), null) }
                "setPref" -> bg {
                    val key = call.argument<String>("key")!!
                    val v = call.argument<String>("value")
                    getSharedPreferences("ui", MODE_PRIVATE).edit().apply { if (v == null) remove(key) else putString(key, v) }.apply()
                }
                // 홈: 순간(시간 구간) 목록과 한 순간의 사진, 인물을 고르면 그 인물만
                "moments" -> bg {
                    Moments(this).list(call.argument<Number>("offset")?.toInt() ?: 0, call.argument<Number>("limit")?.toInt() ?: 40,
                        call.argument<Number>("person")?.toLong())
                }
                "momentPhotos" -> bg { Moments(this).photos(call.argument<Number>("id")!!.toLong(), call.argument<Number>("person")?.toLong()) }
                "reviewQueue" -> bg { Moments(this).review(call.argument<Number>("limit")?.toInt() ?: 100) }
                // 사진 크게 보기의 공유·갤러리에서 열기: 사진 원본은 다른 앱이 MediaStore 주소로 읽는다
                "share", "openInGallery" -> {
                    val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, call.argument<Number>("id")!!.toLong())
                    val intent = if (call.method == "share")
                        Intent.createChooser(Intent(Intent.ACTION_SEND).setType("image/*").putExtra(Intent.EXTRA_STREAM, uri)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), null)
                    else Intent(Intent.ACTION_VIEW).setDataAndType(uri, "image/*").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    try { startActivity(intent); result.success(true) } catch (e: Exception) {
                        Log.w("PhotoTracer", "${call.method} 못 엶", e); result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        permissionResult?.success(photosGranted())
        permissionResult = null
    }

    private fun status(db: Db): Map<String, Any?> {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        val n = { sql: String -> db.count(sql) }
        return mapOf(
            "photos_permission" to photosGranted(),
            "notifications" to (Build.VERSION.SDK_INT < 33 || granted(Manifest.permission.POST_NOTIFICATIONS)),
            "battery_exempt" to pm.isIgnoringBatteryOptimizations(packageName),
            "manufacturer" to Build.MANUFACTURER,
            "running" to Indexer.isRunning(),
            "rest_why" to Indexer.restWhy,
            "rest_left" to ((Indexer.restUntil - System.currentTimeMillis()) / 1000).coerceAtLeast(0),
            "night_on" to IndexWorker.nightOn(this),
            "scan_phase" to Scanner.phase,
            "scan_done" to Scanner.done,
            "scan_total" to Scanner.total,
            "photos" to n("SELECT COUNT(*) FROM photos"),
            "failed" to n("SELECT COUNT(*) FROM photos WHERE failed = 1"),
            "faces_done" to n("SELECT COUNT(*) FROM photos WHERE faces_done = 1"),
            "segments" to n("SELECT COUNT(*) FROM segments"),
            "vec_needed" to n("SELECT COUNT(*) FROM photos p WHERE p.failed = 0 AND ${Db.NEEDS_VECTOR}"),
            "vec_done" to n("SELECT COUNT(*) FROM photos p JOIN vectors v ON v.photo_id = p.id WHERE p.failed = 0 AND ${Db.NEEDS_VECTOR}"),
            "faces" to n("SELECT COUNT(*) FROM faces"),
            // 얼굴 벡터를 새 방식(Models.FACE_VER)으로 다시 만들어야 하는 사진(얼굴 있는 사진)과 끝낸 사진
            "reface_needed" to n("SELECT COUNT(*) FROM photos p WHERE p.faces_done = 1 AND EXISTS (SELECT 1 FROM faces WHERE photo_id = p.id)"),
            "reface_done" to n("SELECT COUNT(*) FROM photos p WHERE p.faces_done = 1 AND p.face_ver >= ${Models.FACE_VER} AND EXISTS (SELECT 1 FROM faces WHERE photo_id = p.id)"),
            "persons" to n("SELECT COUNT(*) FROM (SELECT person FROM faces WHERE person IS NOT NULL GROUP BY person HAVING COUNT(*) >= ${People.MIN_SHOW})"),
        )
    }

    /**
     * 제조사가 따로 두는 백그라운드 설정 화면. 화면 이름은 OS 버전마다 달라 앞에서부터 열어 보고, 다 안 되면 앱 정보로.
     *   샤오미 HyperOS: 앱 정보에 자동 시작이 없고 보안 앱의 자동 시작 목록에 있다 (Redmi OS1.0에서 확인)
     *   삼성 One UI: 배터리 → 백그라운드 사용 제한 → 절전 예외 앱 목록 (실기기 미확인 — 갤럭시에서 시험 필요)
     */
    private fun openVendorSettings() {
        val screens = when {
            Regex("xiaomi|redmi|poco", RegexOption.IGNORE_CASE).containsMatchIn(Build.MANUFACTURER) -> listOf(
                "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity")
            Build.MANUFACTURER.equals("samsung", ignoreCase = true) -> listOf(
                "com.samsung.android.lool" to "com.samsung.android.sm.battery.ui.usage.CheckableAppListActivity",
                "com.samsung.android.lool" to "com.samsung.android.sm.battery.ui.BatteryActivity",
                "com.samsung.android.lool" to "com.samsung.android.sm.ui.battery.BatteryActivity")
            else -> emptyList()
        }
        for ((pkg, cls) in screens) {
            try { startActivity(Intent().setClassName(pkg, cls)); return } catch (e: Exception) {
                Log.w("PhotoTracer", "설정 화면 못 엶: $cls", e)
            }
        }
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
    }

    private fun ids(db: Db, sql: String, arg: String): List<Long> =
        db.readableDatabase.rawQuery(sql, arrayOf(arg)).use { c -> buildList { while (c.moveToNext()) add(c.getLong(0)) } }

    /** 묶음의 표지 얼굴: 가장 큰 얼굴 */
    private fun longs(v: List<Number>?): List<Long> = v?.map { it.toLong() } ?: emptyList()

    private fun cover(db: Db, person: Long): Long =
        db.readableDatabase.rawQuery("SELECT id FROM faces WHERE person = ? ORDER BY w * h DESC LIMIT 1", arrayOf(person.toString()))
            .use { if (it.moveToFirst()) it.getLong(0) else 0L }

    /** 원본이 받은 썸네일보다 크지 않아 다시 읽을 필요가 없을 때 디코딩을 멈추려고 던진다 */
    private class NotBigger : Exception()

    /** MediaStore가 아는 원본 크기 (모르면 0x0) */
    private fun mediaSize(id: Long): Pair<Int, Int> = try {
        contentResolver.query(
            ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id),
            arrayOf(MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT), null, null, null,
        )?.use { c -> if (c.moveToFirst()) c.getInt(0) to c.getInt(1) else null } ?: (0 to 0)
    } catch (e: Exception) { 0 to 0 }

    /**
     * 썸네일: 긴 변 size px. loadThumbnail(MediaStore 캐시·EXIF 썸네일)이 요청보다 많이 작게 주면(0.8배 미만)
     * 원본이 그보다 클 때 ImageDecoder로 원본에서 긴 변 size로 줄여 다시 읽는다(회전 반영). 실패하면 받은 것 그대로.
     * 원본 자체가 작은 사진은 그대로 둔다(로그로만 본다).
     */
    private fun thumb(id: Long, size: Int): ByteArray {
        val t0 = SystemClock.elapsedRealtime()
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        var bmp = contentResolver.loadThumbnail(uri, Size(size, size), null)
        val got = maxOf(bmp.width, bmp.height)
        var via = "thumb"
        var orig = if (THUMB_LOG || got < size * 0.8) mediaSize(id) else 0 to 0
        if (got < size * 0.8 && (maxOf(orig.first, orig.second) == 0 || maxOf(orig.first, orig.second) > got)) {
            try {
                bmp = ImageDecoder.decodeBitmap(ImageDecoder.createSource(contentResolver, uri)) { dec, info, _ ->
                    val w = info.size.width
                    val h = info.size.height
                    orig = w to h
                    if (maxOf(w, h) <= got) throw NotBigger() // 원본도 작다: 머리만 읽고 멈춘다
                    val s = size.toDouble() / maxOf(w, h)
                    if (s < 1) dec.setTargetSize((w * s).toInt().coerceAtLeast(1), (h * s).toInt().coerceAtLeast(1))
                    dec.allocator = ImageDecoder.ALLOCATOR_SOFTWARE // compress하려면 소프트웨어 비트맵이어야 한다
                }.also { bmp.recycle() }
                via = "decode"
            } catch (e: NotBigger) {
            } catch (e: Exception) {
                if (THUMB_LOG) Log.i(THUMB_TAG, "thumb id=$id decode 실패: ${e.javaClass.simpleName}")
            }
        }
        val w = bmp.width
        val h = bmp.height
        val out = jpeg(bmp)
        if (THUMB_LOG) Log.i(THUMB_TAG, "thumb id=$id req=$size got=${w}x$h orig=${orig.first}x${orig.second} via=$via ms=${SystemClock.elapsedRealtime() - t0}")
        return out
    }

    companion object {
        /**
         * 썸네일 측정 로그(디버그·릴리스 모두). 보기: adb logcat -s PT-thumb
         * 2026-11-12 레드미 실측: 89장 중 86장이 loadThumbnail이 요청의 0.8배 미만이라 원본에서 다시 읽음(평균 0.26초, 최대 0.48초), 원본이 작은 사진 0장. 다 재서 끔
         */
        const val THUMB_LOG = false
        const val THUMB_TAG = "PT-thumb"
    }

    /** 크게 보기용: 원본을 긴 변 max px로 줄여 읽는다(회전 정보 반영). 썸네일(loadThumbnail)은 크게 보면 뭉개진다 */
    private fun photo(id: Long, max: Int): ByteArray {
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        val bmp = ImageDecoder.decodeBitmap(ImageDecoder.createSource(contentResolver, uri)) { dec, info, _ ->
            val w = info.size.width
            val h = info.size.height
            val s = max.toDouble() / maxOf(w, h)
            if (s < 1) dec.setTargetSize((w * s).toInt().coerceAtLeast(1), (h * s).toInt().coerceAtLeast(1))
            dec.allocator = ImageDecoder.ALLOCATOR_SOFTWARE // compress하려면 소프트웨어 비트맵이어야 한다
        }
        return jpeg(bmp)
    }

    /** 얼굴 조각. 기본 160px, '이 사람 맞나요?'처럼 크게 보일 때는 더 크게 */
    private fun faceThumb(faceId: Long, size: Int): ByteArray? = Who(this).faceBitmap(faceId, size.coerceIn(96, 384))?.let { jpeg(it) }

    private fun jpeg(bmp: Bitmap): ByteArray =
        ByteArrayOutputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 85, it); bmp.recycle(); it.toByteArray() }
}
