package com.example.btcalls

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.icing.dialer.KeystoreHelper
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import kotlin.text.removeSuffix

class MainActivity : FlutterActivity() {
    private val CHANNEL = "bt_audio"
    private var server: BluetoothAudioServer? = null
    private var client: BluetoothAudioClient? = null
    private lateinit var methodChannel: MethodChannel
    private val REQUEST_PERMISSIONS = 1001
    private var pendingCall: MethodCall? = null
    private var pendingResult: MethodChannel.Result? = null

    private lateinit var scanReceiver: BroadcastReceiver
    // Invisible marker to append to device name for app discovery
    private val NAME_MARKER = "\u200B"  // zero-width space
    private val btAdapter: BluetoothAdapter? by lazy { BluetoothAdapter.getDefaultAdapter() }
    private var originalAdapterName: String? = null
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Register receiver for Bluetooth device discovery
        scanReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (BluetoothDevice.ACTION_FOUND == intent.action) {
                    val device: BluetoothDevice? = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    device?.name?.let { fullName ->
                        // only include devices broadcasting our invisible marker
                        if (fullName.endsWith(NAME_MARKER)) {
                            val (displayName, hint) = parseNameAndHint(fullName)
                            runOnUiThread {
                                methodChannel.invokeMethod("onDeviceFound", mapOf(
                                    "name" to displayName,
                                    "address" to device.address,
                                    "hint" to hint
                                ))
                            }
                        }
                    }
                }
            }
        }
        registerReceiver(scanReceiver, IntentFilter(BluetoothDevice.ACTION_FOUND))
    }
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startServer" -> {
                    // permission check and request
                    val perms = mutableListOf(Manifest.permission.RECORD_AUDIO)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        perms += Manifest.permission.BLUETOOTH_CONNECT
                        perms += Manifest.permission.BLUETOOTH_SCAN
                    }
                    if (perms.any { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }) {
                        pendingCall = call
                        pendingResult = result
                        ActivityCompat.requestPermissions(this, perms.toTypedArray(), REQUEST_PERMISSIONS)
                        return@setMethodCallHandler
                    }
                    val hint = call.argument<String>("discoveryHint") ?: ""
                    val baseName = sanitizeAdapterName(btAdapter?.name)
                    originalAdapterName = baseName
                    try {
                        btAdapter?.name = composeBroadcastName(baseName, hint)
                    } catch (_: SecurityException) {
                        // ignore if we cannot rename due to permission changes
                    }
                    // request device to be discoverable for 5 minutes
                    val discoverIntent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).apply {
                        putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 300)
                    }
                    startActivity(discoverIntent)
                    val decrypt = call.argument<Boolean>("decrypt") ?: true
                    val encrypt = call.argument<Boolean>("encrypt") ?: true
                    server = BluetoothAudioServer(this@MainActivity, decrypt, encrypt) { method, arg ->
                        runOnUiThread {
                            methodChannel.invokeMethod(method, arg)
                        }
                    }
                    server?.startServer()
                    result.success(null)
                }
                "startClient" -> {
                    // permission check and request
                    val permsClient = mutableListOf(Manifest.permission.RECORD_AUDIO)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        permsClient += Manifest.permission.BLUETOOTH_CONNECT
                        permsClient += Manifest.permission.BLUETOOTH_SCAN
                    }
                    if (permsClient.any { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }) {
                        pendingCall = call
                        pendingResult = result
                        ActivityCompat.requestPermissions(this, permsClient.toTypedArray(), REQUEST_PERMISSIONS)
                        return@setMethodCallHandler
                    }
                    val mac = call.argument<String>("macAddress")!!
                    val decrypt = call.argument<Boolean>("decrypt") ?: true
                    val encrypt = call.argument<Boolean>("encrypt") ?: true
                    client = BluetoothAudioClient(this@MainActivity, decrypt, encrypt) { method, arg ->
                        runOnUiThread {
                            methodChannel.invokeMethod(method, arg)
                        }
                    }
                    client?.startClient(mac)
                    result.success(null)
                }
                "stop" -> {
                    server?.stop()
                    client?.stop()
                    restoreAdapterName()
                    // notify Flutter of stopped status
                    runOnUiThread {
                        methodChannel.invokeMethod("onStatus", "stopped")
                    }
                    result.success(null)
                }
                "startScan" -> {
                    // permission check for scanning: location (M+), Bluetooth scan & connect (S+)
                    val permsScan = mutableListOf<String>()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        permsScan += Manifest.permission.BLUETOOTH_SCAN
                        permsScan += Manifest.permission.BLUETOOTH_CONNECT
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        permsScan += Manifest.permission.ACCESS_FINE_LOCATION
                    }
                    if (permsScan.any { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }) {
                        pendingCall = call
                        pendingResult = result
                        ActivityCompat.requestPermissions(this, permsScan.toTypedArray(), REQUEST_PERMISSIONS)
                        return@setMethodCallHandler
                    }
                    // start discovery
                    btAdapter?.apply {
                        if (isDiscovering) cancelDiscovery()
                        startDiscovery()
                        result.success(null)
                    } ?: result.error("NO_ADAPTER", "Bluetooth adapter not available", null)
                }
                "stopScan" -> {
                    btAdapter?.cancelDiscovery()
                    result.success(null)
                }
                "setDecrypt" -> {
                    // Toggle decryption mid-stream
                    val decrypt = call.argument<Boolean>("decrypt") ?: true
                    server?.toggleDecryption(decrypt)
                    client?.toggleDecryption(decrypt)
                    result.success(null)
                }
                "setEncrypt" -> {
                    // Toggle encryption mid-stream
                    val encrypt = call.argument<Boolean>("encrypt") ?: true
                    server?.toggleEncryption(encrypt)
                    client?.toggleEncryption(encrypt)
                    result.success(null)
                }
                "setSpeaker" -> {
                    // Toggle speakerphone mid-call
                    val enabled = call.argument<Boolean>("speaker") ?: false
                    server?.toggleSpeaker(enabled)
                    client?.toggleSpeaker(enabled)
                    result.success(null)
                }
                "endCall" -> {
                    android.util.Log.d("MainActivity", "endCall method called")
                    // Stop the connection - closing the stream will signal end of call to remote side
                    server?.stop()
                    client?.stop()
                    restoreAdapterName()
                    
                    // notify Flutter of stopped status
                    runOnUiThread {
                        methodChannel.invokeMethod("onStatus", "stopped")
                        methodChannel.invokeMethod("onCallEnded", null)
                    }
                    result.success(null)
                }
                "getLocalDeviceInfo" -> {
                    val name = btAdapter?.name ?: ""
                    var address = ""
                    val hasConnectPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
                    } else {
                        ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH) == PackageManager.PERMISSION_GRANTED
                    }
                    if (hasConnectPermission) {
                        try {
                            address = btAdapter?.address ?: ""
                        } catch (_: SecurityException) {
                            address = ""
                        }
                    }
                    result.success(mapOf("name" to name, "address" to address))
                }
                else -> result.notImplemented()
            }
        }
        // Keystore crypto plugin channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.keystore").setMethodCallHandler { call, result ->
            KeystoreHelper(call, result).handleMethodCall()
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        try { unregisterReceiver(scanReceiver) } catch (_: Exception) {}
        restoreAdapterName()
    }

    private fun sanitizeAdapterName(current: String?): String {
        if (current.isNullOrEmpty()) return "Bluetooth"
        var sanitized = current.removeSuffix(NAME_MARKER)
        val bracketIndex = sanitized.lastIndexOf(" [")
        if (bracketIndex >= 0 && sanitized.endsWith(']')) {
            val potentialHint = sanitized.substring(bracketIndex + 2, sanitized.length - 1)
            if (isLikelyHint(potentialHint)) {
                sanitized = sanitized.substring(0, bracketIndex)
            }
        }
        return sanitized.trim()
    }

    private fun composeBroadcastName(base: String, hint: String): String {
        val trimmedBase = base.trim()
        return if (hint.isNotEmpty()) "$trimmedBase [$hint]$NAME_MARKER" else trimmedBase + NAME_MARKER
    }

    private fun parseNameAndHint(encoded: String): Pair<String, String> {
        val trimmed = encoded.removeSuffix(NAME_MARKER)
        val bracketIndex = trimmed.lastIndexOf(" [")
        return if (bracketIndex >= 0 && trimmed.endsWith(']')) {
            val hint = trimmed.substring(bracketIndex + 2, trimmed.length - 1).trim()
            if (isLikelyHint(hint)) {
                val name = trimmed.substring(0, bracketIndex).trim()
                Pair(name, hint)
            } else {
                Pair(trimmed.trim(), "")
            }
        } else {
            Pair(trimmed.trim(), "")
        }
    }

    private fun isLikelyHint(candidate: String): Boolean {
        if (candidate.length !in 4..16) return false
        return candidate.all { it in 'A'..'Z' || it in '0'..'9' }
    }

    private fun restoreAdapterName() {
        val baseName = originalAdapterName ?: return
        try {
            btAdapter?.name = baseName
        } catch (_: SecurityException) {
            // ignore
        }
        originalAdapterName = null
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_PERMISSIONS) {
            val call = pendingCall
            val result = pendingResult
            pendingCall = null
            pendingResult = null
            if (call == null || result == null) return
            if (grantResults.any { it != PackageManager.PERMISSION_GRANTED }) {
                result.error("PERMISSION_DENIED", "Required permissions denied", null)
                return
            }
            when (call.method) {
                "startServer" -> {
                    val decrypt = call.argument<Boolean>("decrypt") ?: true
                    val encrypt = call.argument<Boolean>("encrypt") ?: true
                    val hint = call.argument<String>("discoveryHint") ?: ""
                    val baseName = sanitizeAdapterName(btAdapter?.name)
                    originalAdapterName = baseName
                    try {
                        btAdapter?.name = composeBroadcastName(baseName, hint)
                    } catch (_: SecurityException) {
                        // ignore
                    }
                    val discoverIntent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).apply {
                        putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 300)
                    }
                    startActivity(discoverIntent)
                    server = BluetoothAudioServer(this@MainActivity, decrypt, encrypt) { method, arg ->
                        runOnUiThread { methodChannel.invokeMethod(method, arg) }
                    }
                    server?.startServer()
                    result.success(null)
                }
                "startClient" -> {
                    val mac = call.argument<String>("macAddress")!!
                    val decrypt = call.argument<Boolean>("decrypt") ?: true
                    val encrypt = call.argument<Boolean>("encrypt") ?: true
                    client = BluetoothAudioClient(this@MainActivity, decrypt, encrypt) { method, arg ->
                        runOnUiThread { methodChannel.invokeMethod(method, arg) }
                    }
                    client?.startClient(mac)
                    result.success(null)
                }
                "startScan" -> {
                    btAdapter?.apply {
                        if (isDiscovering) cancelDiscovery()
                        startDiscovery()
                        pendingResult?.success(null)
                    } ?: pendingResult?.error("NO_ADAPTER", "Bluetooth adapter not available", null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
