package com.hu60.smsgateway

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SubscriptionInfo
import android.telephony.SubscriptionManager
import android.telephony.SmsManager
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "hu60.sms_gateway/sms"
    private val requestPermissionCode = 1901
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    "sendSms" -> {
                        val mobile = call.argument<String>("mobile")
                        val text = call.argument<String>("text")
                        val slot = call.argument<String>("slot")

                        if (mobile == null || mobile.isBlank() || text == null) {
                            result.error("INVALID_ARGS", "mobile and text are required", null)
                            return@setMethodCallHandler
                        }

                        sendSms(mobile, text, slot, result)
                    }
                    "getSmsPermissionStatus" -> {
                        result.success(permissionStatusMap())
                    }
                    "requestSmsPermissions" -> {
                        requestPermissionsCompat(result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun permissionStatusMap(): Map<String, Boolean> {
        val smsGranted =
            ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED
        val phoneGranted =
            ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
        return mapOf(
            "smsGranted" to smsGranted,
            "phoneGranted" to phoneGranted,
            "allGranted" to (smsGranted && phoneGranted),
        )
    }

    private fun requestPermissionsCompat(result: MethodChannel.Result) {
        val current = permissionStatusMap()
        if ((current["allGranted"] == true)) {
            result.success(current)
            return
        }

        if (permissionResult != null) {
            result.error("PERMISSION_IN_PROGRESS", "Permission request already in progress", null)
            return
        }

        permissionResult = result
        val permissions = arrayOf(
            Manifest.permission.SEND_SMS,
            Manifest.permission.READ_PHONE_STATE,
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            ActivityCompat.requestPermissions(this, permissions, requestPermissionCode)
        } else {
            permissionResult?.success(permissionStatusMap())
            permissionResult = null
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode != requestPermissionCode) {
            return
        }

        val pending = permissionResult
        if (pending == null) {
            return
        }

        pending.success(permissionStatusMap())
        permissionResult = null
    }

    private fun sendSms(
        mobile: String,
        text: String,
        slot: String?,
        result: MethodChannel.Result,
    ) {
        if (
            ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS)
                != PackageManager.PERMISSION_GRANTED
        ) {
            result.error("NO_PERMISSION", "SEND_SMS permission not granted", null)
            return
        }

        try {
            val manager = resolveManager(slot)
            manager.sendTextMessage(mobile, null, text, null, null)
            result.success(true)
        } catch (e: Exception) {
            Log.e("Hu60SmsGateway", "sendSms failed", e)
            result.error("SMS_ERROR", e.message, null)
        }
    }

    private fun resolveManager(slot: String?): SmsManager {
        if (slot.isNullOrBlank() || Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) {
            return SmsManager.getDefault()
        }
        val slotIndex = slot.toIntOrNull() ?: return SmsManager.getDefault()
        if (slotIndex < 0) {
            return SmsManager.getDefault()
        }

        val manager = getSystemService(SubscriptionManager::class.java) ?: return SmsManager.getDefault()
        val active = manager.activeSubscriptionInfoList ?: emptyList()
        val info: SubscriptionInfo? = active.firstOrNull { it.simSlotIndex == slotIndex }

        return if (info != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            SmsManager.getSmsManagerForSubscriptionId(info.subscriptionId)
        } else {
            SmsManager.getDefault()
        }
    }
}
