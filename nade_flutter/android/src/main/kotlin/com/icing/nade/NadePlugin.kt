package com.icing.nade

import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** NadePlugin - Android implementation of NADE Flutter plugin */
class NadePlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // Audio configuration
    private val sampleRate = 16000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT
    private val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat) * 2
    
    // Audio I/O
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var audioThread: Thread? = null
    private var isRunning = false
    
    companion object {
        init {
            System.loadLibrary("nadecore")
        }
        
        private const val TAG = "NadePlugin"
    }
    
    // Native methods (JNI to libnadecore.so)
    private external fun nativeInit(keyPem: String, configJson: String?): Int
    private external fun nativeShutdown(): Int
    private external fun nativeStartSession(peerId: String, transport: String): Int
    private external fun nativeStopSession(): Int
    private external fun nativeFeedMicFrame(pcmData: ShortArray, sampleCount: Int): Int
    private external fun nativeProcessRemoteInput(pcmData: ShortArray, sampleCount: Int): Int
    private external fun nativeGetModulatedOutput(outBuffer: ShortArray, maxSamples: Int): Int
    private external fun nativePullSpeakerFrame(outBuffer: ShortArray, maxSamples: Int): Int
    private external fun nativeSetConfig(configJson: String): Int
    private external fun nativeGetStatus(): String
    private external fun nativePingCapability(peerId: String): Int
    
    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "nade_flutter/methods")
        methodChannel.setMethodCallHandler(this)
        
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "nade_flutter/events")
        eventChannel.setStreamHandler(this)
        
        // Set native event callback
        setNativeEventCallback()
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        stopAudioPipeline()
        nativeShutdown()
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {
            "initialize" -> {
                val keyPem = call.argument<String>("keyPem")
                val config = call.argument<Map<String, Any>>("config")
                
                if (keyPem == null) {
                    result.error("INVALID_ARGUMENT", "keyPem is required", null)
                    return
                }
                
                val configJson = config?.let { mapToJson(it) }
                val ret = nativeInit(keyPem, configJson)
                
                if (ret == 0) {
                    result.success(null)
                } else {
                    result.error("INIT_FAILED", "Failed to initialize NADE core: $ret", null)
                }
            }
            
            "startCall" -> {
                val peerId = call.argument<String>("peerId")
                val transport = call.argument<String>("transport")
                
                if (peerId == null || transport == null) {
                    result.error("INVALID_ARGUMENT", "peerId and transport are required", null)
                    return
                }
                
                val ret = nativeStartSession(peerId, transport)
                if (ret == 0) {
                    startAudioPipeline()
                    result.success(true)
                } else {
                    result.success(false)
                }
            }
            
            "stopCall" -> {
                stopAudioPipeline()
                nativeStopSession()
                result.success(null)
            }
            
            "configure" -> {
                val config = call.arguments as? Map<String, Any>
                if (config != null) {
                    val configJson = mapToJson(config)
                    nativeSetConfig(configJson)
                }
                result.success(null)
            }
            
            "getStatus" -> {
                val status = nativeGetStatus()
                // Parse JSON string to map (simplified)
                result.success(mapOf("status" to status))
            }
            
            "isPeerNadeCapable" -> {
                val peerId = call.argument<String>("peerId")
                if (peerId == null) {
                    result.error("INVALID_ARGUMENT", "peerId is required", null)
                    return
                }
                
                nativePingCapability(peerId)
                // Result will come via event callback
                result.success(false) // Placeholder
            }
            
            "shutdown" -> {
                stopAudioPipeline()
                nativeShutdown()
                result.success(null)
            }
            
            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
    
    private fun emitEvent(type: String, message: String, data: Map<String, Any>? = null) {
        mainHandler.post {
            eventSink?.success(mapOf(
                "type" to type,
                "message" to message,
                "data" to data,
                "timestamp" to System.currentTimeMillis()
            ))
        }
    }
    
    private fun setNativeEventCallback() {
        // JNI callback will be set up in native code to call back to this
        // For now, placeholder
    }
    
    private fun startAudioPipeline() {
        if (isRunning) return
        
        isRunning = true
        
        // Initialize AudioRecord (microphone)
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            sampleRate,
            channelConfig,
            audioFormat,
            bufferSize
        )
        
        // Initialize AudioTrack (speaker)
        audioTrack = AudioTrack.Builder()
            .setAudioFormat(AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(audioFormat)
                .build())
            .setBufferSizeInBytes(bufferSize)
            .build()
        
        audioRecord?.startRecording()
        audioTrack?.play()
        
        // Start audio processing thread
        audioThread = Thread {
            processAudio()
        }
        audioThread?.start()
    }
    
    private fun stopAudioPipeline() {
        isRunning = false
        
        audioThread?.join(1000)
        audioThread = null
        
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        
        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null
    }
    
    private fun processAudio() {
        val micBuffer = ShortArray(bufferSize / 2)
        val speakerBuffer = ShortArray(bufferSize / 2)
        val modulatedBuffer = ShortArray(bufferSize * 2)
        
        while (isRunning) {
            try {
                // Capture from microphone
                val readCount = audioRecord?.read(micBuffer, 0, micBuffer.size) ?: 0
                
                if (readCount > 0) {
                    // Feed to NADE core (will encode, encrypt, modulate)
                    nativeFeedMicFrame(micBuffer, readCount)
                    
                    // Get modulated output to send to Bluetooth/speaker
                    val modulatedCount = nativeGetModulatedOutput(modulatedBuffer, modulatedBuffer.size)
                    
                    if (modulatedCount > 0) {
                        // Write modulated audio to output (goes to Bluetooth)
                        audioTrack?.write(modulatedBuffer, 0, modulatedCount)
                    }
                }
                
                // Simulate receiving remote audio (in real scenario, this would come from Bluetooth input)
                // For now we'll process what we're outputting (loopback test)
                // TODO: Properly route Bluetooth SCO input here
                
                // Process incoming remote audio (demodulate, decrypt, decode)
                // nativeProcessRemoteInput(remoteBuffer, remoteCount)
                
                // Pull decoded speaker audio
                val speakerCount = nativePullSpeakerFrame(speakerBuffer, speakerBuffer.size)
                
                // Note: In production, we'd play speakerBuffer to local speaker
                // but modulated audio is already being played to Bluetooth output
                
                Thread.sleep(10) // Prevent tight loop
                
            } catch (e: Exception) {
                e.printStackTrace()
                emitEvent("error", "Audio processing error: ${e.message}")
            }
        }
    }
    
    private fun mapToJson(map: Map<String, Any>): String {
        // Simple JSON serialization (in production, use proper JSON library)
        val sb = StringBuilder("{")
        map.entries.forEachIndexed { index, entry ->
            if (index > 0) sb.append(",")
            sb.append("\"${entry.key}\":")
            
            when (val value = entry.value) {
                is String -> sb.append("\"$value\"")
                is Number -> sb.append(value)
                is Boolean -> sb.append(value)
                is List<*> -> {
                    sb.append("[")
                    value.forEachIndexed { i, item ->
                        if (i > 0) sb.append(",")
                        sb.append(item)
                    }
                    sb.append("]")
                }
                else -> sb.append("null")
            }
        }
        sb.append("}")
        return sb.toString()
    }
}
