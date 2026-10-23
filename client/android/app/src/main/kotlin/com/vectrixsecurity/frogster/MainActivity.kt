package com.vectrixsecurity.frogster

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The app, plus what its sound needs from Android that the native audio
 * library cannot do itself: the list of microphones and speakers, the
 * microphone permission, and keeping a voice channel alive in the
 * background (see [VoiceCallService]).
 */
class MainActivity : FlutterActivity() {
    private var pendingPermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "frogster/audio").setMethodCallHandler { call, result ->
            when (call.method) {
                "devices" -> result.success(devices(call.argument<Boolean>("capture") ?: true))
                "requestMicrophone" -> requestMicrophone(result)
                "callStarted" -> {
                    VoiceCallService.start(
                        this,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("text") ?: "",
                    )
                    result.success(null)
                }
                "callEnded" -> {
                    VoiceCallService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** What AAudio can be pointed at: the ids are AudioDeviceInfo's, which AAudio takes. */
    private fun devices(capture: Boolean): List<Map<String, Any>> {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val flag = if (capture) AudioManager.GET_DEVICES_INPUTS else AudioManager.GET_DEVICES_OUTPUTS
        return audio.getDevices(flag)
            .filter { it.type in (if (capture) INPUTS else OUTPUTS) }
            .map { mapOf("id" to it.id.toString(), "name" to label(it), "isDefault" to false) }
    }

    private fun label(d: AudioDeviceInfo): String {
        val kind = when (d.type) {
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "Built-in microphone"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Speaker"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Earpiece"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired headset"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "Wired headphones"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth"
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "USB"
            else -> "Audio"
        }
        val product = d.productName?.toString().orEmpty()
        // The built-in parts are named after the phone model; the kind says more.
        return if (product.isBlank() || d.type in BUILT_IN) kind else "$kind: $product"
    }

    private fun requestMicrophone(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MICROPHONE_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MICROPHONE_REQUEST) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
    }

    override fun onDestroy() {
        // The activity going away (swiped out of recents) ends the call too:
        // the Dart side that runs it goes with it.
        if (isFinishing) VoiceCallService.stop(this)
        super.onDestroy()
    }

    companion object {
        private const val MICROPHONE_REQUEST = 7301

        private val BUILT_IN = setOf(
            AudioDeviceInfo.TYPE_BUILTIN_MIC,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
        )

        private val INPUTS = buildSet {
            add(AudioDeviceInfo.TYPE_BUILTIN_MIC)
            add(AudioDeviceInfo.TYPE_WIRED_HEADSET)
            add(AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
            add(AudioDeviceInfo.TYPE_USB_DEVICE)
            if (Build.VERSION.SDK_INT >= 26) add(AudioDeviceInfo.TYPE_USB_HEADSET)
            if (Build.VERSION.SDK_INT >= 31) add(AudioDeviceInfo.TYPE_BLE_HEADSET)
        }

        private val OUTPUTS = buildSet {
            add(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
            add(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)
            add(AudioDeviceInfo.TYPE_WIRED_HEADSET)
            add(AudioDeviceInfo.TYPE_WIRED_HEADPHONES)
            add(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP)
            add(AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
            add(AudioDeviceInfo.TYPE_USB_DEVICE)
            if (Build.VERSION.SDK_INT >= 26) add(AudioDeviceInfo.TYPE_USB_HEADSET)
            if (Build.VERSION.SDK_INT >= 31) add(AudioDeviceInfo.TYPE_BLE_HEADSET)
        }
    }
}
