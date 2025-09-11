package com.example.btcalls

import android.content.Context
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import java.io.IOException
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
import java.util.UUID
import kotlin.concurrent.thread

class BluetoothAudioClient(
    private val context: Context,
    private val decryptEnabled: Boolean,
    private val eventCallback: (method: String, arg: Any?) -> Unit
) {
    private val SERVICE_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private var audioStreamer: AudioStreamer? = null
        private var connectedSocket: android.bluetooth.BluetoothSocket? = null

    fun startClient(mac: String) {
        thread {
            try {
                val adapter = BluetoothAdapter.getDefaultAdapter()
                val device: BluetoothDevice = adapter.getRemoteDevice(mac)
                val socket: BluetoothSocket = device.createRfcommSocketToServiceRecord(SERVICE_UUID)
                adapter.cancelDiscovery()
                socket.connect()
                
                // Send connected device information to Flutter
                val deviceName = device.name ?: "Unknown Device"
                val deviceAddress = device.address
                
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
        // Generate client EC key pair
        val kpg = KeyPairGenerator.getInstance("EC").apply { initialize(256) }
        val keyPair = kpg.generateKeyPair()
        // Send client's public key
        val clientPubBytes = keyPair.public.encoded
        dout.writeInt(clientPubBytes.size)
        dout.write(clientPubBytes)
        dout.flush()
        // Read server's public key
        val serverPubLen = din.readInt()
        val serverPubBytes = ByteArray(serverPubLen)
        din.readFully(serverPubBytes)
        val serverPubKey = KeyFactory.getInstance("EC")
            .generatePublic(X509EncodedKeySpec(serverPubBytes))
        // Derive shared secret
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(keyPair.private)
        ka.doPhase(serverPubKey, true)
        val shared = ka.generateSecret()
        // Derive AES key
        val aesKey = MessageDigest.getInstance("SHA-256").digest(shared).copyOf(16)
        val secretKey = SecretKeySpec(aesKey, "AES")
        // Generate IV and send to server
        val iv = ByteArray(16).apply { SecureRandom().nextBytes(this) }
        dout.write(iv)
        dout.flush()
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
    // Create AudioStreamer with rawIn input, decryptCipher, encrypted output
    audioStreamer = AudioStreamer(context, rawIn, decryptCipher, cipherOut) {
        // End call signal received - notify Flutter
        eventCallback("onCallEnded", null)
    }
    audioStreamer?.decryptEnabled = decryptEnabled
        audioStreamer!!.start()
    }

    fun stop() {
        // Stop streaming and close socket
        audioStreamer?.stop()
        connectedSocket?.close()
    }
    
    fun sendEndCallSignal() {
        try {
            // Send signal directly through the AudioStreamer's output stream if available
            audioStreamer?.sendEndCallSignal()
        } catch (e: Exception) {
            // Ignore errors when sending end call signal
            android.util.Log.w("BluetoothAudioClient", "Failed to send end call signal: ${e.message}")
        }
    }
    
    // Toggle decryption display at runtime
    fun toggleDecryption(enabled: Boolean) {
        audioStreamer?.decryptEnabled = enabled
    }
}
