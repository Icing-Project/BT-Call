package com.icing.nade_flutter

import android.util.Log

/**
 * Thin JNI wrapper around the native NADE core implementation.
 */
internal object NadeCore {
    init {
        try {
            System.loadLibrary("nade_core")
        } catch (ex: UnsatisfiedLinkError) {
            Log.e("NadeCore", "Unable to load NADE native library", ex)
            throw ex
        }
    }

    external fun nativeInit(seed: ByteArray): Int
    external fun nativeStartServer(peerKey: ByteArray): Int
    external fun nativeStartClient(peerKey: ByteArray): Int
    external fun nativeStopSession(): Int
    external fun nativeFeedMicFrame(samples: ShortArray, sampleCount: Int): Int
    external fun nativePullSpeakerFrame(buffer: ShortArray, maxSamples: Int): Int
    external fun nativeHandleIncoming(data: ByteArray, length: Int): Int
    external fun nativeGenerateOutgoing(buffer: ByteArray, maxLength: Int): Int
    external fun nativeSetConfig(configJson: String): Int
    external fun nativeDerivePublicKey(seed: ByteArray): ByteArray?

    fun initialize(seed: ByteArray): Boolean = nativeInit(seed) == 0

    fun startServer(peerKey: ByteArray): Boolean = nativeStartServer(peerKey) == 0

    fun startClient(peerKey: ByteArray): Boolean = nativeStartClient(peerKey) == 0

    fun stopSession() {
        nativeStopSession()
    }

    fun feedMicFrame(samples: ShortArray, sampleCount: Int) {
        nativeFeedMicFrame(samples, sampleCount)
    }

    fun pullSpeakerFrame(buffer: ShortArray, maxSamples: Int): Int {
        return nativePullSpeakerFrame(buffer, maxSamples)
    }

    fun handleIncoming(data: ByteArray, length: Int) {
        nativeHandleIncoming(data, length)
    }

    fun generateOutgoing(buffer: ByteArray, maxLength: Int): Int {
        return nativeGenerateOutgoing(buffer, maxLength)
    }

    fun setConfig(configJson: String) {
        nativeSetConfig(configJson)
    }

    fun derivePublicKey(seed: ByteArray): ByteArray? {
        return nativeDerivePublicKey(seed)
    }
}
