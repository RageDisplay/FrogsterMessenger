package com.vectrixsecurity.frogster

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.IBinder

/**
 * Keeps a voice channel going while the app is in the background.
 *
 * Android stops giving an app the microphone once it leaves the screen,
 * unless a foreground service of the microphone type runs; this is that
 * service, with the ongoing notification it needs. It also puts the phone
 * in call mode, which turns on its echo cancellation, and sends the sound
 * to a headset when one is connected and to the loudspeaker otherwise.
 */
class VoiceCallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty()
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty()
        val notification = notification(title, text)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        route(true)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        route(false)
        super.onDestroy()
    }

    // The task swiped away: nothing is left to talk through.
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun notification(title: String, text: String): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Voice channels", NotificationManager.IMPORTANCE_LOW).apply {
                    setShowBadge(false)
                },
            )
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_frogster)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
            .build()
    }

    private fun route(on: Boolean) {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (!on) {
            if (Build.VERSION.SDK_INT >= 31) audio.clearCommunicationDevice()
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = false
            audio.mode = AudioManager.MODE_NORMAL
            return
        }
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        if (Build.VERSION.SDK_INT >= 31) {
            val devices = audio.availableCommunicationDevices
            val choice = devices.firstOrNull { it.type in HEADSETS }
                ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            if (choice != null) audio.setCommunicationDevice(choice)
        } else {
            val outputs = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = outputs.none { it.type in HEADSETS }
        }
    }

    companion object {
        private const val CHANNEL_ID = "voice"
        private const val NOTIFICATION_ID = 7302
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"

        private val HEADSETS = buildSet {
            add(AudioDeviceInfo.TYPE_WIRED_HEADSET)
            add(AudioDeviceInfo.TYPE_WIRED_HEADPHONES)
            add(AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
            add(AudioDeviceInfo.TYPE_USB_HEADSET)
            if (Build.VERSION.SDK_INT >= 31) add(AudioDeviceInfo.TYPE_BLE_HEADSET)
        }

        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, VoiceCallService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, VoiceCallService::class.java))
        }
    }
}
