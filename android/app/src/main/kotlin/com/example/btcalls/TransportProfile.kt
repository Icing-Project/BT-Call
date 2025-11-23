package com.example.btcalls

import org.json.JSONObject

/**
 * Metadata describing the caller that travels during the Bluetooth handshake.
 */
data class TransportProfile(
    val displayName: String,
    val discoveryHint: String,
    val publicKey: String,
) {
    fun toMap(): Map<String, String> = mapOf(
        "displayName" to displayName,
        "discoveryHint" to discoveryHint,
        "publicKey" to publicKey,
    )

    fun toJson(): JSONObject = JSONObject().apply {
        put("displayName", displayName)
        put("discoveryHint", discoveryHint)
        put("publicKey", publicKey)
    }

    companion object {
        fun fromMap(raw: Map<String, Any?>?): TransportProfile? {
            if (raw == null) return null
            val publicKey = (raw["publicKey"] as? String)?.trim().orEmpty()
            val discoveryHint = (raw["discoveryHint"] as? String)?.trim().orEmpty()
            if (publicKey.isEmpty() || discoveryHint.isEmpty()) {
                return null
            }
            val displayName = (raw["displayName"] as? String)?.trim().orEmpty()
            return TransportProfile(
                displayName = if (displayName.isNotEmpty()) displayName else "Unknown",
                discoveryHint = discoveryHint.uppercase(),
                publicKey = publicKey,
            )
        }

        fun fromJson(json: JSONObject?): TransportProfile? {
            if (json == null) return null
            val publicKey = json.optString("publicKey").trim()
            val discoveryHint = json.optString("discoveryHint").trim()
            if (publicKey.isEmpty() || discoveryHint.isEmpty()) {
                return null
            }
            val displayName = json.optString("displayName").trim()
            return TransportProfile(
                displayName = if (displayName.isNotEmpty()) displayName else "Unknown",
                discoveryHint = discoveryHint.uppercase(),
                publicKey = publicKey,
            )
        }
    }
}
