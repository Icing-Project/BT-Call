package com.icing.nade_flutter

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

internal class NadeSession(
    private val context: Context,
    private val eventEmitter: (Map<String, Any?>) -> Unit
) {
    private val sampleRate = 16_000
    private val frameSamples = 320 // 20 ms @ 16 kHz
    private val outgoingBuffer = ByteArray(2048)
    private val incomingBuffer = ByteArray(2048)
    private val speakerBuffer = ShortArray(frameSamples)
    private val micBuffer = ShortArray(frameSamples)

    private val running = AtomicBoolean(false)
    private val transportReady = AtomicBoolean(false)

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var audioFocusRequest: AudioFocusRequest? = null
    private var hasAudioFocus = false
    private var scoRequested = false
    private val recorder: AudioRecord
    private val player: AudioTrack
    private val mainHandler = Handler(Looper.getMainLooper())

    private var micThread: Thread? = null
    private var txThread: Thread? = null
    private var rxThread: Thread? = null
    private var speakerThread: Thread? = null

    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null

    private val configState = JSONObject()
    @Volatile private var hangupSent = false
    @Volatile private var hangupDrainPending = false
    @Volatile private var hangupDrainSucceeded = false
    @Volatile private var remoteHangupNotified = false

    init {
        val minBufRec = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val recSize = if (minBufRec > 0) minBufRec * 2 else 4096
        recorder = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            recSize
        )

        val minBufTrack = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val trackSize = if (minBufTrack > 0) minBufTrack * 2 else 4096
        player = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build(),
            AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build(),
            trackSize,
            AudioTrack.MODE_STREAM,
            AudioManager.AUDIO_SESSION_ID_GENERATE
        )
    }

    fun startServerSession(peerKeyBase64: String): Boolean {
        val peerKeyBytes = decodeKey(peerKeyBase64)
        val ok = NadeCore.startServer(peerKeyBytes)
        if (ok) {
            emitState("server_started")
            ensureThreads()
        }
        return ok
    }

    fun startClientSession(peerKeyBase64: String): Boolean {
        val peerKeyBytes = decodeKey(peerKeyBase64)
        val ok = NadeCore.startClient(peerKeyBytes)
        if (ok) {
            emitState("client_started")
            ensureThreads()
        }
        return ok
    }

    fun attachTransport(input: InputStream, output: OutputStream) {
        inputStream = input
        outputStream = output
        transportReady.set(true)
        emitState("transport_attached")
        ensureThreads()
    }

    fun detachTransport() {
        transportReady.set(false)
        try {
            inputStream?.close()
        } catch (_: IOException) {
        }
        try {
            outputStream?.close()
        } catch (_: IOException) {
        }
        inputStream = null
        outputStream = null
        emitState("transport_detached")
    }

    fun setSpeakerEnabled(enabled: Boolean) {
        try {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            if (!enabled) {
                audioManager.isSpeakerphoneOn = false
                if (audioManager.isBluetoothScoAvailableOffCall) {
                    if (!audioManager.isBluetoothScoOn) {
                        try {
                            audioManager.startBluetoothSco()
                            audioManager.isBluetoothScoOn = true
                            scoRequested = true
                        } catch (ex: Exception) {
                            Log.w("NadeSession", "Failed to start Bluetooth SCO: ${ex.message}")
                        }
                    } else {
                        scoRequested = true
                    }
                }
            } else {
                if (audioManager.isBluetoothScoOn || scoRequested) {
                    try {
                        audioManager.stopBluetoothSco()
                    } catch (ex: Exception) {
                        Log.w("NadeSession", "Failed to stop Bluetooth SCO: ${ex.message}")
                    }
                    audioManager.isBluetoothScoOn = false
                    scoRequested = false
                }
                audioManager.isSpeakerphoneOn = true
            }
        } catch (ex: Exception) {
            Log.w("NadeSession", "Failed to toggle speaker: ${ex.message}")
        }
    }

    fun updateConfiguration(values: Map<String, Any?>) {
        for ((key, value) in values) {
            when (value) {
                is Boolean -> configState.put(key, value)
                is Number -> configState.put(key, value)
                is String -> configState.put(key, value)
            }
            if (key == "speaker" && value is Boolean) {
                setSpeakerEnabled(value)
            }
        }
        NadeCore.setConfig(configState.toString())
    }

    fun stop(sendHangup: Boolean = true) {
        val shouldSignal = sendHangup && transportReady.get() && !hangupSent
        if (shouldSignal) {
            hangupSent = true
            hangupDrainPending = true
            hangupDrainSucceeded = false
            Log.i("NadeSession", "Sending hangup control to remote peer")
            NadeCore.sendHangupSignal()
            waitForHangupDrain()
        }
        running.set(false)
        transportReady.set(false)
        detachTransport()
        try {
            audioManager.stopBluetoothSco()
            audioManager.isBluetoothScoOn = false
        } catch (_: Exception) {
        }
        scoRequested = false
        abandonAudioFocus()
        try {
            recorder.stop()
        } catch (_: Exception) {
        }
        try {
            player.stop()
        } catch (_: Exception) {
        }
        try {
            audioManager.mode = AudioManager.MODE_NORMAL
        } catch (_: Exception) {
        }
        micThread?.interrupt()
        txThread?.interrupt()
        rxThread?.interrupt()
        speakerThread?.interrupt()
        NadeCore.stopSession()
        hangupSent = false
        emitState("stopped")
    }

    private fun waitForHangupDrain(maxWaitMs: Long = 200) {
        val start = SystemClock.elapsedRealtime()
        while (hangupDrainPending && SystemClock.elapsedRealtime() - start < maxWaitMs) {
            try {
                Thread.sleep(5)
            } catch (_: InterruptedException) {
                break
            }
        }
        val elapsed = SystemClock.elapsedRealtime() - start
        when {
            !hangupDrainPending && hangupDrainSucceeded ->
                Log.i("NadeSession", "Hangup control flushed in ${elapsed}ms")
            hangupDrainPending ->
                Log.w("NadeSession", "Hangup flush not confirmed after ${maxWaitMs}ms")
        }
        hangupDrainPending = false
        hangupDrainSucceeded = false
    }

    private fun checkRemoteHangup(tag: String): Boolean {
        if (NadeCore.consumeRemoteHangup()) {
            notifyRemoteHangup(tag)
            return true
        }
        return false
    }

    private fun notifyRemoteHangup(reason: String) {
        if (remoteHangupNotified) {
            Log.d("NadeSession", "Remote hangup already handled, skipping ($reason)")
            return
        }
        remoteHangupNotified = true
        Log.i("NadeSession", "Remote hangup triggered ($reason)")
        mainHandler.post {
            emitState("remote_hangup")
            stop(false)
        }
    }

    private fun ensureThreads() {
        if (running.get()) return
        Log.d("NadeSession", "ensureThreads() called - starting audio session")
        running.set(true)
        remoteHangupNotified = false
        requestAudioFocus()
        try {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        } catch (_: Exception) {
        }
        
        if (recorder.state == AudioRecord.STATE_INITIALIZED) {
            recorder.startRecording()
            Log.d("NadeSession", "AudioRecord started")
        } else {
            emitError("mic_init", Exception("AudioRecord not initialized"))
        }
        
        if (player.state == AudioTrack.STATE_INITIALIZED) {
            player.play()
            Log.d("NadeSession", "AudioTrack started")
        } else {
            emitError("spk_init", Exception("AudioTrack not initialized"))
        }

        setSpeakerEnabled(configState.optBoolean("speaker", false))
        micThread = thread(name = "nade-mic") { captureMicLoop() }
        txThread = thread(name = "nade-tx") { transmitLoop() }
        rxThread = thread(name = "nade-rx") { receiveLoop() }
        speakerThread = thread(name = "nade-spk") { playbackLoop() }
    }

    private fun requestAudioFocus() {
        if (hasAudioFocus) return
        hasAudioFocus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener { /* no-op */ }
                .setAcceptsDelayedFocusGain(false)
                .build()
            audioFocusRequest = request
            audioManager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            val granted = audioManager.requestAudioFocus(
                null,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
            ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            granted
        }
    }

    private fun abandonAudioFocus() {
        if (!hasAudioFocus) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(null)
        }
        audioFocusRequest = null
        hasAudioFocus = false
    }

    private fun captureMicLoop() {
        Log.d("NadeSession", "captureMicLoop started")
        var frames = 0
        try {
            while (running.get()) {
                val read = recorder.read(micBuffer, 0, micBuffer.size)
                if (read > 0) {
                    NadeCore.feedMicFrame(micBuffer, read)
                    frames++
                    if (frames % 100 == 0) Log.d("NadeSession", "Mic captured $frames frames")
                } else if (read < 0) {
                    Log.w("NadeSession", "AudioRecord read error: $read")
                    Thread.sleep(10)
                }
            }
        } catch (ex: Exception) {
            emitError("mic_capture", ex)
        }
    }

    private fun transmitLoop() {
        Log.d("NadeSession", "transmitLoop started")
        var packets = 0
        try {
            while (running.get()) {
                val out = outputStream
                if (!transportReady.get() || out == null) {
                    Thread.sleep(10)
                    continue
                }
                val produced = NadeCore.generateOutgoing(outgoingBuffer, outgoingBuffer.size)
                if (produced > 0) {
                    out.write(outgoingBuffer, 0, produced)
                    out.flush()
                    if (hangupDrainPending) {
                        hangupDrainPending = false
                        hangupDrainSucceeded = true
                        Log.i("NadeSession", "Hangup frame flushed via transmit loop")
                    }
                    packets++
                    if (packets % 100 == 0) Log.d("NadeSession", "Tx sent $packets packets")
                } else {
                    Thread.sleep(4)
                }
            }
        } catch (ex: IOException) {
            if (running.get()) {
                Log.i("NadeSession", "Bluetooth socket closed during transmit: ${ex.message}")
                notifyRemoteHangup("tx_exception")
            }
        } catch (ex: Exception) {
            if (running.get()) emitError("tx_loop", ex)
        }
    }

    private fun receiveLoop() {
        Log.d("NadeSession", "receiveLoop started")
        var packets = 0
        try {
            while (running.get()) {
                val input = inputStream
                if (!transportReady.get() || input == null) {
                    Thread.sleep(10)
                    continue
                }
                if (checkRemoteHangup("pre-read")) {
                    break
                }
                val read = input.read(incomingBuffer)
                if (read > 0) {
                    NadeCore.handleIncoming(incomingBuffer, read)
                    if (checkRemoteHangup("post-frame")) {
                        break
                    }
                    packets++
                    if (packets < 5 || packets % 100 == 0) {
                        Log.d("NadeSession", "Rx received packet #$packets ($read bytes)")
                    }
                } else if (read < 0) {
                    Log.i("NadeSession", "Transport closed by peer (read=$read)")
                    notifyRemoteHangup("socket_eof")
                    emitState("link_closed")
                    break
                }
            }
        } catch (ex: IOException) {
            if (running.get()) {
                Log.i("NadeSession", "Bluetooth socket closed during receive: ${ex.message}")
                notifyRemoteHangup("rx_exception")
            }
        } catch (ex: Exception) {
            if (running.get()) emitError("rx_loop", ex)
        }
    }

    private fun playbackLoop() {
        Log.d("NadeSession", "playbackLoop started")
        var frames = 0
        try {
            while (running.get()) {
                val pulled = NadeCore.pullSpeakerFrame(speakerBuffer, speakerBuffer.size)
                if (pulled > 0) {
                    val written = player.write(speakerBuffer, 0, pulled)
                    if (written < 0) {
                        Log.w("NadeSession", "AudioTrack write error: $written")
                    } else {
                        frames++
                        if (frames % 100 == 0) Log.d("NadeSession", "Speaker played $frames frames")
                    }
                } else {
                    Thread.sleep(4)
                }
            }
        } catch (ex: Exception) {
            emitError("playback", ex)
        }
    }

    private fun decodeKey(value: String): ByteArray {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) {
            return ByteArray(32)
        }
        return try {
            Base64.decode(trimmed, Base64.NO_WRAP or Base64.NO_PADDING)
        } catch (_: IllegalArgumentException) {
            ByteArray(32)
        }
    }

    private fun emitState(state: String) {
        dispatchEvent(mapOf("type" to "state", "value" to state))
    }

    private fun emitError(stage: String, throwable: Throwable) {
        Log.e("NadeSession", "NADE pipeline error at $stage", throwable)
        dispatchEvent(
            mapOf(
                "type" to "error",
                "stage" to stage,
                "message" to (throwable.message ?: stage)
            )
        )
    }

    private fun dispatchEvent(payload: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventEmitter.invoke(payload)
        } else {
            mainHandler.post { eventEmitter.invoke(payload) }
        }
    }
}
