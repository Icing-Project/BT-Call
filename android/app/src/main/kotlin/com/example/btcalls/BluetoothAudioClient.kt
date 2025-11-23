package com.example.btcalls

import android.content.Context
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import java.io.IOException
import com.icing.nade_flutter.NadeTransportBridge
import java.util.UUID
import kotlin.concurrent.thread

class BluetoothAudioClient(
    private val context: Context,
    private val decryptEnabled: Boolean,
    private val encryptEnabled: Boolean,
    private val localProfile: TransportProfile,
    private val eventCallback: (method: String, arg: Any?) -> Unit
) {
    private val SERVICE_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private var connectedSocket: android.bluetooth.BluetoothSocket? = null

    fun startClient(mac: String) {
        thread {
            try {
                val adapter = BluetoothAdapter.getDefaultAdapter()
                val device: BluetoothDevice = adapter.getRemoteDevice(mac)
                val socket: BluetoothSocket = device.createRfcommSocketToServiceRecord(SERVICE_UUID)
                adapter.cancelDiscovery()
                socket.connect()
                
                val remoteProfile = try {
                    ProfileHandshake.exchange(socket, localProfile)
                } catch (ex: IOException) {
                    eventCallback("onError", "profile_handshake_failed: ${ex.message}")
                    socket.close()
                    return@thread
                }

                val deviceName = remoteProfile.displayName.ifEmpty { device.name ?: "Unknown Device" }
                val deviceAddress = device.address
                
                eventCallback("onDeviceConnected", mapOf(
                    "name" to deviceName,
                    "address" to deviceAddress,
                    "hint" to remoteProfile.discoveryHint,
                    "profile" to remoteProfile.toMap()
                ))
                eventCallback("onStatus", "connected")
                setupStreams(socket)
            } catch (e: IOException) {
                eventCallback("onError", e.message)
            }
        }
    }

    private fun setupStreams(socket: BluetoothSocket) {
        connectedSocket = socket
        NadeTransportBridge.attachStreams(socket.inputStream, socket.outputStream)
    }

    fun stop() {
        NadeTransportBridge.detachStreams()
        connectedSocket?.close()
    }
    
    fun sendEndCallSignal() {
        // Signal is now sent by AudioStreamer.stop()
        android.util.Log.d("BluetoothAudioClient", "End call signal handled by AudioStreamer.stop()")
    }
    
    // Toggle decryption display at runtime
    fun toggleDecryption(enabled: Boolean) {
        // handled via NADE configuration on Flutter side
    }
    
    // Toggle encryption at runtime
    fun toggleEncryption(enabled: Boolean) {
        // handled via NADE configuration on Flutter side
    }

    // Toggle speakerphone at runtime
    fun toggleSpeaker(enabled: Boolean) {
        NadeTransportBridge.updateSpeaker(enabled)
    }
}
