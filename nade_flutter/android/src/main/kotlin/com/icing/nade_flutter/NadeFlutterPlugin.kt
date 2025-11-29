package com.icing.nade_flutter

import android.content.Context
import android.util.Base64
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class NadeFlutterPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var applicationContext: Context? = null
    private var session: NadeSession? = null
    private var initialized = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "nade_flutter")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        session?.stop()
        session?.let { NadeTransportBridge.clearBinding(it) }
        session = null
        applicationContext = null
        initialized = false
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize" -> handleInitialize(call, result)
            "startServer" -> handleStartServer(call, result)
            "startClient" -> handleStartClient(call, result)
            "stop" -> handleStop(result)
            "configure" -> handleConfigure(call, result)
            "derivePublicKey" -> handleDerivePublicKey(call, result)
            "refreshPreferredKeys" -> handleRefreshPreferredKeys(call, result)
            // 4-FSK Modulation methods
            "fskSetEnabled" -> handleFskSetEnabled(call, result)
            "fskIsEnabled" -> handleFskIsEnabled(result)
            "fskModulate" -> handleFskModulate(call, result)
            "fskFeedAudio" -> handleFskFeedAudio(call, result)
            "fskPullDemodulated" -> handleFskPullDemodulated(result)
            else -> result.notImplemented()
        }
    }

    private fun handleInitialize(call: MethodCall, result: Result) {
        val seed = call.argument<ByteArray>("identityKeySeed")
        if (seed == null || seed.size != 32) {
            result.error("INVALID_SEED", "identityKeySeed must be 32 bytes", null)
            return
        }
        session?.stop()
        session?.let { NadeTransportBridge.clearBinding(it) }
        session = null
        initialized = NadeCore.initialize(seed)
        result.success(null)
    }

    private fun handleStartServer(call: MethodCall, result: Result) {
        val ctx = applicationContext ?: run {
            result.error("NO_CONTEXT", "Plugin not attached", null)
            return
        }
        if (!initialized) {
            result.error("NOT_INITIALIZED", "Call initialize() before starting a session", null)
            return
        }
        val peerKey = call.argument<String>("peerPublicKeyBase64") ?: ""
        ensureSession(ctx)
        val success = session?.startServerSession(peerKey) ?: false
        result.success(success)
    }

    private fun handleStartClient(call: MethodCall, result: Result) {
        val ctx = applicationContext ?: run {
            result.error("NO_CONTEXT", "Plugin not attached", null)
            return
        }
        if (!initialized) {
            result.error("NOT_INITIALIZED", "Call initialize() before starting a session", null)
            return
        }
        val peerKey = call.argument<String>("peerPublicKeyBase64") ?: ""
        ensureSession(ctx)
        val success = session?.startClientSession(peerKey) ?: false
        result.success(success)
    }

    private fun handleStop(result: Result) {
        session?.stop()
        session?.let { NadeTransportBridge.clearBinding(it) }
        session = null
        result.success(null)
    }

    private fun handleConfigure(call: MethodCall, result: Result) {
        val cfg = call.arguments as? Map<*, *>
        if (cfg == null) {
            result.error("INVALID_CONFIG", "Configuration map expected", null)
            return
        }
        session?.updateConfiguration(cfg as Map<String, Any?>)
        result.success(null)
    }

    private fun handleDerivePublicKey(call: MethodCall, result: Result) {
        val seed = call.argument<ByteArray>("seed")
        if (seed == null || seed.size != 32) {
            result.error("INVALID_SEED", "Seed must be 32 bytes", null)
            return
        }
        val pub = NadeCore.derivePublicKey(seed)
        if (pub == null || pub.size != 32) {
            result.error("DERIVE_FAILED", "Unable to derive NADE public key", null)
            return
        }
        val encoded = Base64.encodeToString(pub, Base64.NO_WRAP)
        result.success(encoded)
    }

    private fun handleRefreshPreferredKeys(call: MethodCall, result: Result) {
        val alias = call.argument<String>("deletedAlias")
        Log.i("NadeFlutterPlugin", "Refresh preferred keys request received (deleted: $alias)")
        result.success(null)
    }

    // -------------------------------------------------------------------------
    // 4-FSK Modulation handlers

    private fun handleFskSetEnabled(call: MethodCall, result: Result) {
        val enabled = call.argument<Boolean>("enabled") ?: true
        val success = NadeCore.setFskEnabled(enabled)
        result.success(success)
    }

    private fun handleFskIsEnabled(result: Result) {
        val enabled = NadeCore.isFskEnabled()
        result.success(enabled)
    }

    private fun handleFskModulate(call: MethodCall, result: Result) {
        val data = call.argument<ByteArray>("data")
        if (data == null || data.isEmpty()) {
            result.error("INVALID_DATA", "Data must be a non-empty byte array", null)
            return
        }
        // Calculate required output size: 320 samples per byte
        val samplesNeeded = NadeCore.fskSamplesForBytes(data.size)
        val pcmOut = ShortArray(samplesNeeded)
        val produced = NadeCore.fskModulate(data, pcmOut)
        // Return only the samples that were actually produced
        val trimmed = if (produced < samplesNeeded) pcmOut.copyOf(produced) else pcmOut
        result.success(trimmed)
    }

    private fun handleFskFeedAudio(call: MethodCall, result: Result) {
        val pcm = call.argument<ShortArray>("pcm")
        if (pcm == null || pcm.isEmpty()) {
            result.error("INVALID_PCM", "PCM must be a non-empty short array", null)
            return
        }
        NadeCore.fskFeedAudio(pcm, pcm.size)
        result.success(null)
    }

    private fun handleFskPullDemodulated(result: Result) {
        // Use a reasonable buffer size
        val buffer = ByteArray(4096)
        val pulled = NadeCore.fskPullDemodulated(buffer)
        val trimmed = if (pulled > 0) buffer.copyOf(pulled) else ByteArray(0)
        result.success(trimmed)
    }

    private fun ensureSession(ctx: Context) {
        if (session != null) return
        val created = NadeSession(ctx, ::emitEvent)
        session = created
        NadeTransportBridge.bind(created)
    }

    private fun emitEvent(payload: Map<String, Any?>) {
        channel.invokeMethod("event", payload)
    }
}
