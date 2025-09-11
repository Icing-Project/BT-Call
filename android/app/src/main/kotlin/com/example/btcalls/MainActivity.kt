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
                            val displayName = fullName.removeSuffix(NAME_MARKER)
                            runOnUiThread {
                                methodChannel.invokeMethod("onDeviceFound", mapOf(
                                    "name" to displayName,
                                    "address" to device.address
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
                    // set adapter name with invisible marker for our app
                    val baseName = btAdapter?.name ?: "Bluetooth"
                    btAdapter?.name = baseName + NAME_MARKER
                    // request device to be discoverable for 5 minutes
                    val discoverIntent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).apply {
                        putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 300)
                    }
                    startActivity(discoverIntent)
                    val decrypt = call.argument<Boolean>("decrypt") ?: true
                    server = BluetoothAudioServer(this@MainActivity, decrypt) { method, arg ->
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
                    client = BluetoothAudioClient(this@MainActivity, decrypt) { method, arg ->
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
                "endCall" -> {
                    // Send end call signal to remote device before stopping
                    try {
                        server?.sendEndCallSignal()
                        client?.sendEndCallSignal()
                        
                        // Add a small delay to ensure signal is sent
                        Thread.sleep(100)
                    } catch (e: Exception) {
                        android.util.Log.w("MainActivity", "Error sending end call signal: ${e.message}")
                    }
                    
                    // Then stop the connection
                    server?.stop()
                    client?.stop()
                    
                    // notify Flutter of stopped status
                    runOnUiThread {
                        methodChannel.invokeMethod("onStatus", "stopped")
                        methodChannel.invokeMethod("onCallEnded", null)
                    }
                    result.success(null)
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
                    server = BluetoothAudioServer(this@MainActivity, decrypt) { method, arg ->
                        runOnUiThread { methodChannel.invokeMethod(method, arg) }
                    }
                    server?.startServer()
                    result.success(null)
                }
                "startClient" -> {
                    val mac = call.argument<String>("macAddress")!!
                    val decrypt = call.argument<Boolean>("decrypt") ?: true
                    client = BluetoothAudioClient(this@MainActivity, decrypt) { method, arg ->
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
