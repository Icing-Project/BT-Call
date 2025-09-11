package com.example.btcalls

import android.media.*
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.media.audiofx.AcousticEchoCanceler
import android.content.Context
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import kotlin.concurrent.thread
// Removed simple XOR encryption; using Cipher streams instead

class AudioStreamer(
    private val context: Context,
    private val rawIn: InputStream,
    private val decryptCipher: javax.crypto.Cipher,
    private val btOut: OutputStream,
    private val onEndCallReceived: () -> Unit = {}
) {
    @Volatile private var running = true
    // Toggle whether to decrypt incoming audio
    @Volatile var decryptEnabled: Boolean = true

    private val SAMPLE_RATE = 16000
    private val CHANNEL_IN = AudioFormat.CHANNEL_IN_MONO
    private val CHANNEL_OUT = AudioFormat.CHANNEL_OUT_MONO
    private val ENCODING = AudioFormat.ENCODING_PCM_16BIT
    
    // Audio processing components for echo cancellation
    private var echoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var automaticGainControl: AutomaticGainControl? = null
    
    // Audio manager for routing and mode control
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var previousAudioMode = AudioManager.MODE_NORMAL

    private val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_IN, ENCODING)
    private val recorder = AudioRecord(
        MediaRecorder.AudioSource.VOICE_COMMUNICATION,
        SAMPLE_RATE, CHANNEL_IN, ENCODING, minBuf * 2
    )
    private val player = AudioTrack(
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .setLegacyStreamType(AudioManager.STREAM_VOICE_CALL) // Use voice call stream for earpiece
            .build(),
        AudioFormat.Builder()
            .setEncoding(ENCODING)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(CHANNEL_OUT)
            .build(),
        minBuf * 2,
        AudioTrack.MODE_STREAM,
        AudioManager.AUDIO_SESSION_ID_GENERATE
    )

    fun start() {
        setupAudioMode()
        initAudioEffects()
        thread { captureAndSend() }
        thread { receiveAndPlay() }
    }
    
    private fun setupAudioMode() {
        try {
            // Save previous audio mode
            previousAudioMode = audioManager.mode
            
            // Set audio mode to in-call for better echo cancellation
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            
            // Disable speaker phone - use earpiece for better call quality
            audioManager.isSpeakerphoneOn = false
            
            // Set audio routing to earpiece
            audioManager.isBluetoothScoOn = false
            audioManager.isWiredHeadsetOn = false
            
            // Request audio focus for voice communication
            audioManager.requestAudioFocus(
                null, // No focus change listener needed
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN
            )
        } catch (e: Exception) {
            android.util.Log.w("AudioStreamer", "Failed to setup audio mode: ${e.message}")
        }
    }
    
    private fun initAudioEffects() {
        try {
            // Initialize Acoustic Echo Canceler - less aggressive for earpiece
            if (AcousticEchoCanceler.isAvailable()) {
                echoCanceler = AcousticEchoCanceler.create(recorder.audioSessionId)
                echoCanceler?.enabled = true
            }
            
            // Initialize Noise Suppressor - moderate setting
            if (NoiseSuppressor.isAvailable()) {
                noiseSuppressor = NoiseSuppressor.create(recorder.audioSessionId)
                noiseSuppressor?.enabled = true
            }
            
            // Disable Automatic Gain Control for earpiece mode to preserve audio quality
            if (AutomaticGainControl.isAvailable()) {
                automaticGainControl = AutomaticGainControl.create(recorder.audioSessionId)
                automaticGainControl?.enabled = false // Disabled for better audio quality
            }
        } catch (e: Exception) {
            // Audio effects may not be available on all devices
            android.util.Log.w("AudioStreamer", "Failed to initialize audio effects: ${e.message}")
        }
    }

    private fun captureAndSend() {
        try {
            recorder.startRecording()
            val buf = ByteArray(minBuf * 2) // Use larger buffer to match player
            while (running) {
                val read = recorder.read(buf, 0, buf.size)
                if (read > 0) {
                    // Write raw audio (streams are already encrypted/decrypted)
                    btOut.write(buf, 0, read)
                }
            }
        } catch (e: IOException) {
            // socket closed or write error - stop loop
        } finally {
            try { recorder.stop() } catch (_: Exception) {}
        }
    }

    private fun receiveAndPlay() {
        try {
            player.play()
            // Set volume higher for earpiece mode (no feedback risk)
            player.setVolume(1.0f)
            
            val buf = ByteArray(minBuf * 2) // Use larger buffer to match recorder
            while (running) {
                // Always read ciphertext from rawIn
                val count = rawIn.read(buf)
                if (count > 0) {
                    // Check for end call signal (0xFF, 0xFF, 0x00, 0x00)
                    if (count >= 4 && 
                        buf[0] == 0xFF.toByte() && buf[1] == 0xFF.toByte() && 
                        buf[2] == 0x00.toByte() && buf[3] == 0x00.toByte()) {
                        // End call signal received
                        onEndCallReceived()
                        break
                    }
                    
                    // Always update cipher state to stay in sync
                    val decrypted = decryptCipher.update(buf, 0, count)
                    if (decryptEnabled) {
                        // Play decrypted audio - no delay needed in earpiece mode
                        player.write(decrypted, 0, decrypted.size)
                    } else {
                        // Play encrypted bytes directly
                        player.write(buf, 0, count)
                    }
                }
            }
        } catch (e: IOException) {
            // socket closed or read error - exit loop
        } finally {
            try { player.stop() } catch (_: Exception) {}
        }
    }

    fun stop() {
        running = false
        
        // Release audio effects
        try {
            echoCanceler?.release()
            noiseSuppressor?.release()
            automaticGainControl?.release()
        } catch (e: Exception) {
            android.util.Log.w("AudioStreamer", "Failed to release audio effects: ${e.message}")
        }
        
        // Restore audio settings
        try {
            audioManager.mode = previousAudioMode
            audioManager.isSpeakerphoneOn = false
            audioManager.isBluetoothScoOn = false
            audioManager.abandonAudioFocus(null)
        } catch (e: Exception) {
            android.util.Log.w("AudioStreamer", "Failed to restore audio settings: ${e.message}")
        }
        
        recorder.release()
        player.release()
        rawIn.close()
        btOut.close()
    }
    
    fun sendEndCallSignal() {
        try {
            val endCallSignal = byteArrayOf(0xFF.toByte(), 0xFF.toByte(), 0x00.toByte(), 0x00.toByte())
            btOut.write(endCallSignal)
            btOut.flush()
        } catch (e: Exception) {
            android.util.Log.w("AudioStreamer", "Failed to send end call signal: ${e.message}")
        }
    }
    
    // No explicit setter needed; flip decryptEnabled to toggle decryption in-flight
}
