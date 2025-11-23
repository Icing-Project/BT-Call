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
