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

    // -------------------------------------------------------------------------
    // Reed-Solomon Error Correction API
    // RS(255, 223) - can correct up to 16 byte errors per 255-byte block

    // JNI declarations
    external fun nativeRsSetEnabled(enabled: Boolean): Int
    external fun nativeRsIsEnabled(): Boolean
    external fun nativeRsEncode(data: ByteArray, dataLen: Int, out: ByteArray, maxOut: Int): Int
    external fun nativeRsDecode(codeword: ByteArray, len: Int): Int
    external fun nativeRsEncodedLen(dataLen: Int): Int
    external fun nativeRsDataLen(encodedLen: Int): Int
    external fun nativeRsGetStats(): String

    /**
     * Enable or disable Reed-Solomon error correction.
     * When enabled, RS encoding is automatically applied to FSK transmissions.
     */
    fun setRsEnabled(enabled: Boolean): Boolean {
        return nativeRsSetEnabled(enabled) == 0
    }

    /**
     * Check if Reed-Solomon error correction is currently enabled.
     */
    fun isRsEnabled(): Boolean {
        return nativeRsIsEnabled()
    }

    /**
     * Get RS statistics as a data class for logging.
     * Returns: encodes, decodes, clean frames, errors corrected, uncorrectable
     */
    data class RsStats(
        val encodes: Long,
        val decodes: Long,
        val cleanFrames: Long,
        val errorsCorrected: Long,
        val uncorrectable: Long
    )
    
    fun getRsStats(): RsStats {
        val statsStr = nativeRsGetStats()
        val parts = statsStr.split(",")
        return if (parts.size == 5) {
            RsStats(
                encodes = parts[0].toLongOrNull() ?: 0,
                decodes = parts[1].toLongOrNull() ?: 0,
                cleanFrames = parts[2].toLongOrNull() ?: 0,
                errorsCorrected = parts[3].toLongOrNull() ?: 0,
                uncorrectable = parts[4].toLongOrNull() ?: 0
            )
        } else {
            RsStats(0, 0, 0, 0, 0)
        }
    }

    /**
     * Encode data with Reed-Solomon parity (adds 32 parity bytes).
     * @param data The data to encode
     * @param out Output buffer (must be at least data.size + 32)
     * @return Total encoded length (data + parity), or 0 on error
     */
    fun rsEncode(data: ByteArray, out: ByteArray): Int {
        return nativeRsEncode(data, data.size, out, out.size)
    }

    /**
     * Decode and correct errors in Reed-Solomon codeword.
     * Corrects data in-place.
     * @param codeword The received codeword (data + parity)
     * @return Number of errors corrected, or -1 if uncorrectable
     */
    fun rsDecode(codeword: ByteArray): Int {
        return nativeRsDecode(codeword, codeword.size)
    }

    /**
     * Get encoded length for given data length (data_len + 32 parity bytes).
     */
    fun rsEncodedLen(dataLen: Int): Int {
        return nativeRsEncodedLen(dataLen)
    }

    /**
     * Get data length from encoded length (encoded_len - 32 parity bytes).
     */
    fun rsDataLen(encodedLen: Int): Int {
        return nativeRsDataLen(encodedLen)
    }
}
