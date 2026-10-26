package com.reddol18.photo_tracer

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/**
 * 밤 작업 일정. 충전 중일 때 15분마다 깨어나 남은 사진을 이어 한다(이미 돌고 있으면 그대로 둔다).
 * 길게 돌아야 하므로 포그라운드 서비스(FGS)로 올린다 — 알림창에 진행률이 보인다.
 *   FGS 종류: Android 15부터는 mediaProcessing(미디어 처리), 14 이하는 dataSync. 둘 다 하루 6시간 제한이 있을 수 있다.
 *   백그라운드에서 FGS를 띄우려면 배터리 최적화 예외가 필요하다(Android 12+). 못 띄우면 FGS 없이 돈다 —
 *   이때는 시스템이 약 10분 뒤 멈추고, 다음 15분 주기에 이어 한다. 어느 쪽이었는지 기록(runs.note)에 남긴다.
 */
class IndexWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    companion object {
        const val CHANNEL = "index"
        const val NOTE_ID = 1

        fun scheduleNight(ctx: Context) {
            val req = PeriodicWorkRequestBuilder<IndexWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiresCharging(true).build())
                .setInputData(workDataOf("mode" to "night"))
                .build()
            WorkManager.getInstance(ctx).enqueueUniquePeriodicWork("night", ExistingPeriodicWorkPolicy.KEEP, req)
        }

        /** 시험용: 충전·화면 조건 없이 지금 돌린다 */
        fun startNow(ctx: Context) {
            val req = OneTimeWorkRequestBuilder<IndexWorker>().setInputData(workDataOf("mode" to "now")).build()
            WorkManager.getInstance(ctx).enqueueUniqueWork("now", ExistingWorkPolicy.KEEP, req)
        }

        /** 도는 작업은 스스로 끝내게 하고(기록에 '사용자가 멈춤'), 아직 시작 전인 시험 작업은 취소한다 */
        fun stopNow(ctx: Context) {
            if (Indexer.isRunning()) Indexer.requestStop() else WorkManager.getInstance(ctx).cancelUniqueWork("now")
        }

        /** 갤러리 스캔만. 앱 화면에서 돌리면 샤오미가 앱을 얼려(GreezeManager) 다른 앱으로 가면 멈춘다 — FGS로 올린다 */
        fun scanNow(ctx: Context) {
            val req = OneTimeWorkRequestBuilder<IndexWorker>().setInputData(workDataOf("mode" to "scan")).build()
            WorkManager.getInstance(ctx).enqueueUniqueWork("scan", ExistingWorkPolicy.KEEP, req)
        }

        // WorkInfo.STOP_REASON_* (= JobParameters 값)
        private val STOP = mapOf(1 to "앱이 취소", 2 to "다른 작업에 밀림", 3 to "시간 초과", 4 to "기기 상태",
            5 to "배터리 부족", 6 to "충전 끊김", 7 to "네트워크", 8 to "기기 사용 중", 9 to "저장 공간 부족",
            10 to "실행 할당량 초과", 11 to "백그라운드 제한", 12 to "앱 대기 버킷", 13 to "사용자가 멈춤",
            14 to "시스템 처리", 15 to "앱 실행 예측 변경")
    }

    private val mode = inputData.getString("mode") ?: "night"

    override suspend fun doWork(): Result {
        val note = try {
            setForeground(foregroundInfo(0, 0))
            "FGS ${if (Build.VERSION.SDK_INT >= 35) "mediaProcessing" else "dataSync"}"
        } catch (e: Throwable) {
            Log.w("PhotoTracer", "FGS를 띄우지 못함", e)
            "FGS 못 띄움: ${e.javaClass.simpleName}"
        }
        val indexer = Indexer(applicationContext, mode, { isStopped }) { done, total ->
            if (done % 10 == 0 || done == total) notify(done, total)
        }
        // 멈추라는 신호가 오면 코루틴이 취소되어 이 블록 뒤는 돌지 않는다 — 멈춘 이유는 블록 안에서 남긴다
        withContext(Dispatchers.IO) {
            Scanner(applicationContext).scan { done, total -> notify(done, total, "갤러리 읽는 중") }
            if (mode == "scan") return@withContext
            val stop = indexer.run(note)
            if (isStopped && stop != Indexer.USER_STOP && Build.VERSION.SDK_INT >= 31) indexer.stoppedBy("시스템이 멈춤: ${STOP[stopReason] ?: stopReason}")
            Log.i("PhotoTracer", "밤 작업 끝($mode): $stop")
        }
        return Result.success()
    }

    private fun notify(done: Int, total: Int, title: String = "사진 정리 중") {
        val nm = applicationContext.getSystemService(NotificationManager::class.java)
        try { nm.notify(NOTE_ID, notification(done, total, title)) } catch (_: SecurityException) {}
    }

    private fun notification(done: Int, total: Int, title: String = "사진 정리 중"): android.app.Notification {
        val nm = applicationContext.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "사진 정리", NotificationManager.IMPORTANCE_LOW))
        }
        return NotificationCompat.Builder(applicationContext, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_gallery)
            .setContentTitle(title)
            .setContentText(if (total > 0) "%,d / %,d장".format(done, total) else "준비 중")
            .setProgress(total, done, total == 0)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    private fun foregroundInfo(done: Int, total: Int): ForegroundInfo {
        val type = if (Build.VERSION.SDK_INT >= 35) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
                   else ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        return ForegroundInfo(NOTE_ID, notification(done, total), type)
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = foregroundInfo(0, 0)
}
