package com.reddol18.photo_tracer

import android.Manifest
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
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
                    result.success(null)
                }
                "setNight" -> { IndexWorker.setNight(this, call.argument<Boolean>("on") == true); result.success(null) }
                "startNow" -> { IndexWorker.startNow(this); result.success(null) }
                "stopNow" -> { IndexWorker.stopNow(this); result.success(null) }
                "search" -> bg { Search(this).search(call.argument<String>("q") ?: "") }
                "segmentPhotos" -> bg {
                    ids(db, "SELECT id FROM photos WHERE segment = ? ORDER BY taken_at", call.argument<Number>("id").toString())
                }
                "persons" -> bg {
                    val out = ArrayList<Map<String, Any>>()
                    db.readableDatabase.rawQuery("""SELECT person, COUNT(DISTINCT photo_id) n, MIN(id) FROM faces
                        WHERE person IS NOT NULL GROUP BY person HAVING COUNT(*) >= ${People.MIN_SHOW} ORDER BY n DESC""", null).use {
                        while (it.moveToNext()) out.add(mapOf("id" to it.getLong(0), "n" to it.getInt(1), "face" to cover(db, it.getLong(0))))
                    }
                    out
                }
                "personPhotos" -> bg { People(this).photos(call.argument<Number>("id")!!.toLong()) }
                "recluster" -> bg { People(this).full() }
                // 등록한 인물
                "people" -> bg { Who(this).people() }
                "whoPhotos" -> bg { Who(this).photos(call.argument<Number>("id")!!.toLong()) }
                "whoCreate" -> bg { Who(this).create(call.argument<String>("name")!!, longs(call.argument("faces"))) }
                "whoRename" -> bg { Who(this).rename(call.argument<Number>("id")!!.toLong(), call.argument<String>("name")!!) }
                "whoDelete" -> bg { Who(this).delete(call.argument<Number>("id")!!.toLong()) }
                "whoMark" -> bg { Who(this).mark(call.argument<Number>("id")!!.toLong(), longs(call.argument("faces")), call.argument<Boolean>("ok") == true) }
                "whoConfirm" -> bg { Who(this).confirmPhotos(call.argument<Number>("id")!!.toLong(), longs(call.argument("photos"))) }
                "whoReject" -> bg { Who(this).rejectPhotos(call.argument<Number>("id")!!.toLong(), longs(call.argument("photos"))) }
                "whoMerge" -> bg { Who(this).merge(longs(call.argument("ids"))) }
                "thumb" -> bg(thumbs) { thumb(call.argument<Number>("id")!!.toLong(), call.argument<Int>("size") ?: 256) }
                "faceThumb" -> bg(thumbs) { faceThumb(db, call.argument<Number>("id")!!.toLong()) }
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
            "night_on" to IndexWorker.nightOn(this),
            "scan_phase" to Scanner.phase,
            "scan_done" to Scanner.done,
            "scan_total" to Scanner.total,
            "photos" to n("SELECT COUNT(*) FROM photos"),
            "failed" to n("SELECT COUNT(*) FROM photos WHERE failed = 1"),
            "faces_done" to n("SELECT COUNT(*) FROM photos WHERE faces_done = 1"),
            "segments" to n("SELECT COUNT(*) FROM segments"),
            "vec_needed" to n("SELECT COUNT(*) FROM photos p WHERE ${Db.NEEDS_VECTOR}"),
            "vec_done" to n("SELECT COUNT(*) FROM photos p JOIN vectors v ON v.photo_id = p.id WHERE ${Db.NEEDS_VECTOR}"),
            "faces" to n("SELECT COUNT(*) FROM faces"),
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

    private fun thumb(id: Long, size: Int): ByteArray {
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        val bmp = contentResolver.loadThumbnail(uri, Size(size, size), null)
        return jpeg(bmp)
    }

    private fun faceThumb(db: Db, faceId: Long): ByteArray? {
        val f = db.readableDatabase.rawQuery("SELECT photo_id, x, y, w, h FROM faces WHERE id = ?", arrayOf(faceId.toString())).use {
            if (!it.moveToFirst()) return null
            listOf(it.getDouble(0), it.getDouble(1), it.getDouble(2), it.getDouble(3), it.getDouble(4))
        }
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, f[0].toLong())
        val bmp = contentResolver.loadThumbnail(uri, Size(768, 768), null)
        // 얼굴 상자에 여백 30%
        val cx = (f[1] + f[3] / 2) * bmp.width; val cy = (f[2] + f[4] / 2) * bmp.height
        val half = maxOf(f[3] * bmp.width, f[4] * bmp.height) * 0.65
        val r = Rect((cx - half).toInt().coerceAtLeast(0), (cy - half).toInt().coerceAtLeast(0),
                     (cx + half).toInt().coerceAtMost(bmp.width), (cy + half).toInt().coerceAtMost(bmp.height))
        if (r.width() < 2 || r.height() < 2) return jpeg(bmp)
        val crop = Bitmap.createBitmap(bmp, r.left, r.top, r.width(), r.height())
        bmp.recycle()
        return jpeg(Bitmap.createScaledBitmap(crop, 160, 160, true))
    }

    private fun jpeg(bmp: Bitmap): ByteArray =
        ByteArrayOutputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 85, it); bmp.recycle(); it.toByteArray() }
}
