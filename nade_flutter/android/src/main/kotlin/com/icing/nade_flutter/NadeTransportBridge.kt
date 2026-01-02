package com.icing.nade_flutter

import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicReference

/**
 * Exposes hooks for the host Android app to provide Bluetooth streams
 * to the NADE session running inside this plugin.
 */
object NadeTransportBridge {
    private val sessionRef = AtomicReference<NadeSession?>()
    private val pendingStreams = AtomicReference<Pair<InputStream, OutputStream>?>(null)

    internal fun bind(session: NadeSession) {
        sessionRef.set(session)
        pendingStreams.getAndSet(null)?.let { (pendingIn, pendingOut) ->
            session.attachTransport(pendingIn, pendingOut)
        }
    }

    internal fun clearBinding(session: NadeSession) {
        pendingStreams.getAndSet(null)?.let { (pendingIn, pendingOut) ->
            try {
                pendingIn.close()
            } catch (_: Exception) {
            }
            try {
                pendingOut.close()
            } catch (_: Exception) {
            }
        }
        sessionRef.compareAndSet(session, null)
    }

    @JvmStatic
    fun attachStreams(input: InputStream, output: OutputStream) {
        val session = sessionRef.get()
        if (session != null) {
            session.attachTransport(input, output)
        } else {
            pendingStreams.getAndSet(input to output)?.let { (oldIn, oldOut) ->
                try {
                    oldIn.close()
                } catch (_: Exception) {
                }
                try {
                    oldOut.close()
                } catch (_: Exception) {
                }
            }
        }
    }

    @JvmStatic
    fun detachStreams() {
        pendingStreams.getAndSet(null)?.let { (pendingIn, pendingOut) ->
            try {
                pendingIn.close()
            } catch (_: Exception) {
            }
            try {
                pendingOut.close()
            } catch (_: Exception) {
            }
        }
        sessionRef.get()?.detachTransport()
    }

    @JvmStatic
    fun updateSpeaker(enabled: Boolean) {
        sessionRef.get()?.setSpeakerEnabled(enabled)
    }
}
