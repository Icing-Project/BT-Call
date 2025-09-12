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
    private val rawOut: OutputStream,
    private val cipherOut: javax.crypto.CipherOutputStream,
    private val encryptCipher: javax.crypto.Cipher,
    private val onEndCallReceived: () -> Unit = {}
) {
    @Volatile private var running = true
    // Toggle whether to decrypt incoming audio
    @Volatile var decryptEnabled: Boolean = true
    // Toggle whether to encrypt outgoing audio
    @Volatile var encryptEnabled: Boolean = true
    // Delay signal detection for first few seconds to avoid false positives
    private var signalDetectionEnabled = false
    // Track start time to ensure minimum call duration
    private var startTime = 0L
    // Skip first few reads after signal detection is enabled
    private var readsAfterEnable = 0
    // Require multiple consecutive signal detections to avoid false positives
    private var consecutiveSignalCount = 0
    // Flag to prevent multiple termination attempts
    private var terminationInitiated = false

    private val SAMPLE_RATE = 16000
    // Maximum latency cap in ms for playback
    private val MAX_LATENCY_MS = 500
    // Maximum buffered bytes (2 bytes per sample) to maintain MAX_LATENCY_MS
    private val MAX_LATENCY_BYTES = SAMPLE_RATE * 2 * MAX_LATENCY_MS / 1000
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
        startTime = System.currentTimeMillis()
        consecutiveSignalCount = 0 // Reset signal count
        terminationInitiated = false // Reset termination flag
        setupAudioMode()
        initAudioEffects()
        // Enable signal detection after 2 seconds to avoid false positives during connection
        thread {
            Thread.sleep(2000)
            signalDetectionEnabled = true
            consecutiveSignalCount = 0 // Reset count when enabling
            android.util.Log.d("AudioStreamer", "Signal detection enabled")
        }
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
                    // Advance encryption cipher state for synchronization
                    val encrypted = encryptCipher.update(buf, 0, read)
                    // Send ciphertext or plaintext based on encryption setting
                    if (encryptEnabled) {
                        rawOut.write(encrypted, 0, read)
                    } else {
                        rawOut.write(buf, 0, read)
                    }
                }
            }
        } catch (e: IOException) {
            // Any IOException during an active call is treated as end call signal
            android.util.Log.d("AudioStreamer", "IOException in captureAndSend: ${e.message} - treating as end call")
            if (!terminationInitiated) {
                terminationInitiated = true
                onEndCallReceived()
            }
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
                // Drop old buffered data to limit latency, syncing cipher state
                try {
                    val available = rawIn.available()
                    val toDrop = available - MAX_LATENCY_BYTES
                    if (toDrop > 0) {
                        var remaining = toDrop
                        val dropBuf = ByteArray(minOf(buf.size, remaining))
                        while (remaining > 0) {
                            val r = rawIn.read(dropBuf, 0, minOf(dropBuf.size, remaining))
                            if (r <= 0) break
                            // Advance decryption cipher state for skipped bytes
                            decryptCipher.update(dropBuf, 0, r)
                            remaining -= r
                        }
                    }
                } catch (_: IOException) {
                }
                // Always read ciphertext from rawIn
                val count = rawIn.read(buf)
                if (count > 0) {
                    // Always update cipher state to stay in sync
                    val decrypted = decryptCipher.update(buf, 0, count)
                    
                    // Check for end call signal in decrypted data
                    var signalFound = false
                    val currentTime = System.currentTimeMillis()
                    if (!terminationInitiated && signalDetectionEnabled && decrypted.size >= 32 && (currentTime - startTime) > 1000 && readsAfterEnable > 5) {
                        // Check for 32-byte alternating pattern ONLY at the beginning of the buffer
                        var isSignal = true
                        for (i in 0..31) {
                            val expected = if (i % 2 == 0) 0xAA.toByte() else 0x55.toByte()
                            if (decrypted[i] != expected) {
                                isSignal = false
                                break
                            }
                        }
                        if (isSignal) {
                            signalFound = true
                            android.util.Log.d("AudioStreamer", "32-byte alternating end call signal found at buffer start")
                        }
                        
                        // Also check for the old 4-byte signal at the beginning for backward compatibility
                        if (!signalFound && decrypted.size >= 4) {
                            if (decrypted[0] == 0xFF.toByte() && decrypted[1] == 0xFF.toByte() && 
                                decrypted[2] == 0x00.toByte() && decrypted[3] == 0x00.toByte()) {
                                signalFound = true
                                android.util.Log.d("AudioStreamer", "4-byte end call signal found at buffer start")
                            }
                        }
                    }
                    
                    if (signalDetectionEnabled) {
                        readsAfterEnable++
                    }
                    
                    // Require 3 consecutive signal detections to avoid false positives
                    if (signalFound) {
                        consecutiveSignalCount++
                        android.util.Log.d("AudioStreamer", "Signal detection count: $consecutiveSignalCount")
                        if (consecutiveSignalCount >= 3 && !terminationInitiated) {
                            terminationInitiated = true
                            android.util.Log.d("AudioStreamer", "End call signal confirmed - terminating call")
                            onEndCallReceived()
                            break
                        }
                    } else {
                        // Reset counter if no signal found
                        if (consecutiveSignalCount > 0) {
                            android.util.Log.d("AudioStreamer", "Signal detection reset")
                            consecutiveSignalCount = 0
                        }
                    }
                    
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
            // Any IOException during an active call is treated as end call signal
            android.util.Log.d("AudioStreamer", "IOException in receiveAndPlay: ${e.message} - treating as end call")
            if (!terminationInitiated) {
                terminationInitiated = true
                onEndCallReceived()
            }
        } finally {
            try { player.stop() } catch (_: Exception) {}
        }
    }

    fun stop() {
        running = false
        
        // Send a final end call signal before closing streams
        try {
            // Use a distinctive signal pattern (32 bytes) with alternating high/low values
            val endCallSignal = ByteArray(32)
            for (i in 0..31) {
                endCallSignal[i] = if (i % 2 == 0) 0xAA.toByte() else 0x55.toByte()
            }
            // Always advance encryption cipher state for synchronization
            val encryptedSignal = encryptCipher.update(endCallSignal)
            // Send signal through the appropriate stream based on encryption setting
            if (encryptEnabled) {
                rawOut.write(encryptedSignal)
                rawOut.flush()
            } else {
                rawOut.write(endCallSignal)
                rawOut.flush()
            }
            android.util.Log.d("AudioStreamer", "Final end call signal sent before closing")
        } catch (e: Exception) {
            android.util.Log.w("AudioStreamer", "Failed to send final end call signal: ${e.message}")
        }
        
        // Small delay to ensure signal is sent
        try {
            Thread.sleep(200)
        } catch (e: Exception) {}
        
        // Close both output streams
        try {
            cipherOut.close()
            rawOut.close()
        } catch (e: Exception) {
            android.util.Log.w("AudioStreamer", "Error closing output streams: ${e.message}")
        }
        
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
    }
    
    fun sendEndCallSignal() {
        // Signal is now sent by stop() method
        android.util.Log.d("AudioStreamer", "sendEndCallSignal called - signal handled by stop()")
    }
    
    // No explicit setter needed; flip decryptEnabled to toggle decryption in-flight
    
    // Allows toggling speakerphone on/off at runtime
    fun toggleSpeaker(enabled: Boolean) {
        try {
            audioManager.isSpeakerphoneOn = enabled
            android.util.Log.d("AudioStreamer", "Speakerphone set to $enabled")
        } catch (e: Exception) {
            android.util.Log.w("AudioStreamer", "Failed to toggle speakerphone: ${e.message}")
        }
    }
}
