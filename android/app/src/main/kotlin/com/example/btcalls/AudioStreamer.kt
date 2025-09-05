package com.example.btcalls

import android.media.*
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import kotlin.concurrent.thread
// Removed simple XOR encryption; using Cipher streams instead

class AudioStreamer(
    private val rawIn: InputStream,
    private val decryptCipher: javax.crypto.Cipher,
    private val btOut: OutputStream
) {
    @Volatile private var running = true
    // Toggle whether to decrypt incoming audio
    @Volatile var decryptEnabled: Boolean = true

    private val SAMPLE_RATE = 16000
    private val CHANNEL_IN = AudioFormat.CHANNEL_IN_MONO
    private val CHANNEL_OUT = AudioFormat.CHANNEL_OUT_MONO
    private val ENCODING = AudioFormat.ENCODING_PCM_16BIT

    private val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_IN, ENCODING)
    private val recorder = AudioRecord(
        MediaRecorder.AudioSource.MIC,
        SAMPLE_RATE, CHANNEL_IN, ENCODING, minBuf
    )
    private val player = AudioTrack(
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build(),
        AudioFormat.Builder()
            .setEncoding(ENCODING)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(CHANNEL_OUT)
            .build(),
        minBuf,
        AudioTrack.MODE_STREAM,
        AudioManager.AUDIO_SESSION_ID_GENERATE
    )

    fun start() {
        thread { captureAndSend() }
        thread { receiveAndPlay() }
    }

    private fun captureAndSend() {
        try {
            recorder.startRecording()
            val buf = ByteArray(minBuf)
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
            val buf = ByteArray(minBuf)
            while (running) {
                // Always read ciphertext from rawIn
                val count = rawIn.read(buf)
                if (count > 0) {
                    // Always update cipher state to stay in sync
                    val decrypted = decryptCipher.update(buf, 0, count)
                    if (decryptEnabled) {
                        // Play decrypted audio
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
        recorder.release()
        player.release()
        rawIn.close()
        btOut.close()
    }
    // No explicit setter needed; flip decryptEnabled to toggle decryption in-flight
}
