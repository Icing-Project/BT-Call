package com.example.btcalls

import android.bluetooth.BluetoothSocket
import android.util.Log
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException

object ProfileHandshake {
    private const val MAX_PROFILE_BYTES = 8 * 1024 // 8 KB safety cap

    @Throws(IOException::class)
    fun exchange(socket: BluetoothSocket, localProfile: TransportProfile): TransportProfile {
        val input = DataInputStream(socket.getInputStream())
        val output = DataOutputStream(socket.getOutputStream())

        val payload = localProfile.toJson().toString().toByteArray(Charsets.UTF_8)
        output.writeInt(payload.size)
        output.write(payload)
        output.flush()

        val incomingLength = input.readInt()
        if (incomingLength <= 0 || incomingLength > MAX_PROFILE_BYTES) {
            throw IOException("Invalid profile length: $incomingLength")
        }
        val buffer = ByteArray(incomingLength)
        input.readFully(buffer)
        val remoteJson = try {
            JSONObject(String(buffer, Charsets.UTF_8))
        } catch (ex: Exception) {
            Log.e("ProfileHandshake", "Invalid JSON payload", ex)
            throw IOException("Remote profile malformed", ex)
        }
        return TransportProfile.fromJson(remoteJson)
            ?: throw IOException("Remote profile missing required fields")
    }
}
