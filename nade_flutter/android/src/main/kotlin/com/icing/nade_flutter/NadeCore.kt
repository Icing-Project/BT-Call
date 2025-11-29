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
    external fun nativeSendHangupSignal(): Int
    external fun nativeConsumeRemoteHangup(): Boolean

    // 4-FSK Modulation JNI declarations
    external fun nativeFskSetEnabled(enabled: Boolean): Int
    external fun nativeFskIsEnabled(): Boolean
    external fun nativeFskModulate(data: ByteArray, dataLen: Int, pcmOut: ShortArray, maxSamples: Int): Int
    external fun nativeFskFeedAudio(pcm: ShortArray, samples: Int): Int
    external fun nativeFskPullDemodulated(out: ByteArray, maxLen: Int): Int
    external fun nativeFskSamplesForBytes(byteCount: Int): Int

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

    fun sendHangupSignal() {
        nativeSendHangupSignal()
    }

    fun consumeRemoteHangup(): Boolean {
        return nativeConsumeRemoteHangup()
    }

    // -------------------------------------------------------------------------
    // 4-FSK Modulation API
    // Converts encrypted data bytes <-> audio tones for "audio over audio" transport

    /**
     * Enable or disable 4-FSK modulation.
     * When enabled, data is converted to audio tones for transmission over voice channels.
     */
    fun setFskEnabled(enabled: Boolean): Boolean {
        return nativeFskSetEnabled(enabled) == 0
    }

    /**
     * Check if 4-FSK modulation is currently enabled.
     */
    fun isFskEnabled(): Boolean {
        return nativeFskIsEnabled()
    }

    /**
     * Modulate data bytes into PCM audio samples.
     * Each byte produces 320 PCM samples (4 symbols * 80 samples/symbol).
     * @param data The encrypted data to modulate
     * @param pcmOut Output buffer for PCM samples
     * @return Number of PCM samples written
     */
    fun fskModulate(data: ByteArray, pcmOut: ShortArray): Int {
        return nativeFskModulate(data, data.size, pcmOut, pcmOut.size)
    }

    /**
     * Feed received PCM audio for demodulation.
     * Call fskPullDemodulated() after to retrieve decoded bytes.
     * @param pcm Received audio samples
     */
    fun fskFeedAudio(pcm: ShortArray, sampleCount: Int) {
        nativeFskFeedAudio(pcm, sampleCount)
    }

    /**
     * Pull demodulated bytes after feeding audio.
     * @param out Output buffer for decoded bytes
     * @return Number of bytes decoded
     */
    fun fskPullDemodulated(out: ByteArray): Int {
        return nativeFskPullDemodulated(out, out.size)
    }

    /**
     * Calculate PCM samples needed to modulate given number of bytes.
     * (320 samples per byte = 4 symbols * 80 samples/symbol)
     */
    fun fskSamplesForBytes(byteCount: Int): Int {
        return nativeFskSamplesForBytes(byteCount)
    }
}
