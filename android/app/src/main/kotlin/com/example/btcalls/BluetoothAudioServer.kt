package com.example.btcalls

import android.content.Context
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import java.io.IOException
import java.util.UUID
import kotlin.concurrent.thread
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.KeyPairGenerator
import java.security.KeyFactory
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.spec.SecretKeySpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.CipherInputStream
import javax.crypto.CipherOutputStream
import java.security.MessageDigest
import java.security.SecureRandom

class BluetoothAudioServer(
    private val context: Context,
    private val decryptEnabled: Boolean,
    private val encryptEnabled: Boolean,
    private val eventCallback: (method: String, arg: Any?) -> Unit
) {
    private val SERVICE_NAME = "BTCallsService"
    private val SERVICE_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private var serverSocket: BluetoothServerSocket? = null
        private var connectedSocket: android.bluetooth.BluetoothSocket? = null
        private var audioStreamer: AudioStreamer? = null

    fun startServer() {
        thread {
            try {
                val adapter = BluetoothAdapter.getDefaultAdapter()
                serverSocket = adapter.listenUsingRfcommWithServiceRecord(SERVICE_NAME, SERVICE_UUID)
                eventCallback("onStatus", "listening")
                val socket = serverSocket!!.accept()
                serverSocket!!.close()
                
                // Get connected device information and send to Flutter
                val remoteDevice = socket.remoteDevice
                val deviceName = remoteDevice.name ?: "Unknown Device"
                val deviceAddress = remoteDevice.address
                
                eventCallback("onDeviceConnected", mapOf(
                    "name" to deviceName,
                    "address" to deviceAddress
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
        // Perform ECDH handshake and wrap streams with AES/CTR encryption
        val rawIn = socket.inputStream
        val rawOut = socket.outputStream
        val din = DataInputStream(rawIn)
        val dout = DataOutputStream(rawOut)
        // Generate server EC key pair
        val kpg = KeyPairGenerator.getInstance("EC").apply { initialize(256) }
        val keyPair = kpg.generateKeyPair()
        // Read client's public key
        val clientPubLen = din.readInt()
        val clientPubBytes = ByteArray(clientPubLen)
        din.readFully(clientPubBytes)
        val clientPubKey = KeyFactory.getInstance("EC")
            .generatePublic(X509EncodedKeySpec(clientPubBytes))
        // Send server's public key
        val serverPubBytes = keyPair.public.encoded
        dout.writeInt(serverPubBytes.size)
        dout.write(serverPubBytes)
        dout.flush()
        // Derive shared secret
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(keyPair.private)
        ka.doPhase(clientPubKey, true)
        val shared = ka.generateSecret()
        // Derive AES key (128-bit) from SHA-256 of secret
        val aesKey = MessageDigest.getInstance("SHA-256").digest(shared).copyOf(16)
        val secretKey = SecretKeySpec(aesKey, "AES")
        // Read IV from client
        val iv = ByteArray(16)
        din.readFully(iv)
        val ivSpec = IvParameterSpec(iv)
        // Initialize ciphers
        val encryptCipher = Cipher.getInstance("AES/CTR/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, secretKey, ivSpec)
        }
        val decryptCipher = Cipher.getInstance("AES/CTR/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, secretKey, ivSpec)
        }
    // Wrap output stream for encryption
    val cipherOut = CipherOutputStream(rawOut, encryptCipher)
    // Create AudioStreamer with input rawIn and decryption cipher, encrypted output
    audioStreamer = AudioStreamer(context, rawIn, decryptCipher, rawOut, cipherOut, encryptCipher) {
        // End call signal received - notify Flutter
        android.util.Log.d("BluetoothAudioServer", "End call signal received, notifying Flutter")
        eventCallback("onCallEnded", null)
    }
    // Set initial decryption and encryption modes
    audioStreamer?.decryptEnabled = decryptEnabled
    audioStreamer?.encryptEnabled = encryptEnabled
        audioStreamer!!.start()
    }

    fun stop() {
        // Stop streaming and close sockets
        audioStreamer?.stop()
        connectedSocket?.close()
        serverSocket?.close()
    }
    
    fun sendEndCallSignal() {
        // Signal is now sent by AudioStreamer.stop()
        android.util.Log.d("BluetoothAudioServer", "End call signal handled by AudioStreamer.stop()")
    }
    
    // Toggle decryption at runtime
    fun toggleDecryption(enabled: Boolean) {
        audioStreamer?.decryptEnabled = enabled
    }
    
    // Toggle encryption at runtime
    fun toggleEncryption(enabled: Boolean) {
        audioStreamer?.encryptEnabled = enabled
    }
}
