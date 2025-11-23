package com.icing.dialer

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

class KeystoreHelper(private val call: MethodCall, private val result: MethodChannel.Result) {

    private val ANDROID_KEYSTORE = "AndroidKeyStore"

    fun handleMethodCall() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error("UNSUPPORTED_API", "ED25519 requires Android 11 (API 30) or higher", null)
            return
        }
        when (call.method) {
            "generateKeyPair" -> generateEDKeyPair()
            "signData" -> signData()
            "getPublicKey" -> getPublicKey()
            "deleteKeyPair" -> deleteKeyPair()
            "keyPairExists" -> keyPairExists()
            else -> result.notImplemented()
        }
    }

    private fun generateEDKeyPair() {
        val alias = call.argument<String>("alias")
        if (alias == null) {
            result.error("INVALID_ARGUMENT", "Alias is required", null)
            return
        }

        try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

            if (keyStore.containsAlias(alias)) {
                result.error("KEY_EXISTS", "Key with alias \"$alias\" already exists.", null)
                return
            }

            val keyPairGenerator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC,
                ANDROID_KEYSTORE
            )
            val parameterSpec = KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec("ed25519"))
                .setUserAuthenticationRequired(false)
                .build()
            keyPairGenerator.initialize(parameterSpec)
            keyPairGenerator.generateKeyPair()

            result.success(null)
        } catch (e: Exception) {
            result.error("KEY_GENERATION_FAILED", e.message, null)
        }
    }

    private fun signData() {
        val alias = call.argument<String>("alias")
        val data = call.argument<String>("data")
        if (alias == null || data == null) {
            result.error("INVALID_ARGUMENT", "Alias and data are required", null)
            return
        }

        try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            val privateKey = keyStore.getKey(alias, null) as? PrivateKey ?: run {
                result.error("KEY_NOT_FOUND", "Private key not found for alias \"$alias\".", null)
                return
            }
            val signature = Signature.getInstance("Ed25519")
            signature.initSign(privateKey)
            signature.update(data.toByteArray())
            val signedBytes = signature.sign()
            val signatureBase64 = Base64.encodeToString(signedBytes, Base64.DEFAULT)
            result.success(signatureBase64)
        } catch (e: Exception) {
            result.error("SIGNING_FAILED", e.message, null)
        }
    }

    private fun getPublicKey() {
        val alias = call.argument<String>("alias")
        if (alias == null) {
            result.error("INVALID_ARGUMENT", "Alias is required", null)
            return
        }

        try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

            val certificate = keyStore.getCertificate(alias) ?: run {
                result.error("CERTIFICATE_NOT_FOUND", "Certificate not found for alias \"$alias\".", null)
                return
            }

            val publicKey = certificate.publicKey
            val publicKeyBase64 = Base64.encodeToString(publicKey.encoded, Base64.DEFAULT)
            result.success(publicKeyBase64)
        } catch (e: Exception) {
            result.error("PUBLIC_KEY_RETRIEVAL_FAILED", e.message, null)
        }
    }

    private fun deleteKeyPair() {
        val alias = call.argument<String>("alias")
        if (alias == null) {
            result.error("INVALID_ARGUMENT", "Alias is required", null)
            return
        }

        try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

            if (!keyStore.containsAlias(alias)) {
                result.error("KEY_NOT_FOUND", "No key found with alias \"$alias\" to delete.", null)
                return
            }

            keyStore.deleteEntry(alias)
            result.success(null)
        } catch (e: Exception) {
            result.error("KEY_DELETION_FAILED", e.message, null)
        }
    }

    private fun keyPairExists() {
        val alias = call.argument<String>("alias")
        if (alias == null) {
            result.error("INVALID_ARGUMENT", "Alias is required", null)
            return
        }

        try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            val exists = keyStore.containsAlias(alias)
            result.success(exists)
        } catch (e: Exception) {
            result.error("KEY_CHECK_FAILED", e.message, null)
        }
    }
}
