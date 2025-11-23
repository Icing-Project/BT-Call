package com.example.btcalls

import android.content.Context
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import java.io.IOException
import java.util.UUID
import kotlin.concurrent.thread
import com.icing.nade_flutter.NadeTransportBridge

class BluetoothAudioServer(
    private val context: Context,
    private val decryptEnabled: Boolean,
    private val encryptEnabled: Boolean,
    private val localProfile: TransportProfile,
    private val eventCallback: (method: String, arg: Any?) -> Unit
) {
    private val SERVICE_NAME = "BTCallsService"
    private val SERVICE_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private var serverSocket: BluetoothServerSocket? = null
        private var connectedSocket: android.bluetooth.BluetoothSocket? = null

    fun startServer() {
        thread {
            try {
                val adapter = BluetoothAdapter.getDefaultAdapter()
                serverSocket = adapter.listenUsingRfcommWithServiceRecord(SERVICE_NAME, SERVICE_UUID)
                eventCallback("onStatus", "listening")
                val socket = serverSocket!!.accept()
                serverSocket!!.close()
                
                val remoteProfile = try {
                    ProfileHandshake.exchange(socket, localProfile)
                } catch (ex: IOException) {
                    eventCallback("onError", "profile_handshake_failed: ${ex.message}")
                    socket.close()
                    return@thread
                }

                val remoteDevice = socket.remoteDevice
                val deviceAddress = remoteDevice.address
                val deviceName = remoteProfile.displayName.ifEmpty { remoteDevice.name ?: "Unknown Device" }

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
        serverSocket?.close()
    }
    
    fun sendEndCallSignal() {
        // Signal is now sent by AudioStreamer.stop()
        android.util.Log.d("BluetoothAudioServer", "End call signal handled by AudioStreamer.stop()")
    }
    
    // Toggle decryption at runtime
    fun toggleDecryption(enabled: Boolean) {
        // handled by NADE configure on Flutter side
    }
    
    // Toggle encryption at runtime
    fun toggleEncryption(enabled: Boolean) {
        // handled by NADE configure on Flutter side
    }
    // Toggle speakerphone at runtime
    fun toggleSpeaker(enabled: Boolean) {
        NadeTransportBridge.updateSpeaker(enabled)
    }
}
