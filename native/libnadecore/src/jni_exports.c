/**
 * JNI Exports for Android
 * Bridges Kotlin/Java to libnadecore C functions
 */

#include <jni.h>
#include <string.h>
#include <android/log.h>
#include "nade_core.h"

#define LOG_TAG "NADE-JNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// Global reference to Java callback object
static JavaVM *g_jvm = NULL;
static jobject g_callback_obj = NULL;

// Event callback from C to Java
static void jni_event_callback(int event_type, const char *message, void *user_data) {
    if (!g_jvm || !g_callback_obj) return;
    
    JNIEnv *env;
    int attached = 0;
    
    // Attach to JVM if needed
    if (g_jvm->GetEnv((void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if (g_jvm->AttachCurrentThread(&env, NULL) != JNI_OK) {
            LOGE("Failed to attach thread to JVM");
            return;
        }
        attached = 1;
    }
    
    // TODO: Call Java method to emit event
    // For now, just log
    LOGI("Event: type=%d, message=%s", event_type, message);
    
    if (attached) {
        g_jvm->DetachCurrentThread();
    }
}

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    g_jvm = vm;
    LOGI("NADE JNI loaded");
    return JNI_VERSION_1_6;
}

extern "C" {

JNIEXPORT jint JNICALL
Java_com_icing_nade_NadePlugin_nativeInit(JNIEnv *env, jobject thiz, jstring key_pem, jstring config_json) {
    const char *key_pem_str = env->GetStringUTFChars(key_pem, NULL);
    const char *config_str = config_json ? env->GetStringUTFChars(config_json, NULL) : NULL;
    
    // Set event callback
    nade_set_event_callback(jni_event_callback, NULL);
    
    int ret = nade_init(key_pem_str, config_str);
    
    env->ReleaseStringUTFChars(key_pem, key_pem_str);
    if (config_str) {
        env->ReleaseStringUTFChars(config_json, config_str);
    }
    
    return ret;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_NadePlugin_nativeShutdown(JNIEnv *env, jobject thiz) {
    return nade_shutdown();
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_NadePlugin_nativeStartSession(JNIEnv *env, jobject thiz, jstring peer_id, jstring transport) {
    const char *peer_id_str = env->GetStringUTFChars(peer_id, NULL);
    const char *transport_str = env->GetStringUTFChars(transport, NULL);
    
    int ret = nade_start_session(peer_id_str, transport_str);
    
    env->ReleaseStringUTFChars(peer_id, peer_id_str);
    env->ReleaseStringUTFChars(transport, transport_str);
    
    return ret;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_NadePlugin_nativeStopSession(JNIEnv *env, jobject thiz) {
    return nade_stop_session();
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_NadePlugin_nativeFeedMicFrame(JNIEnv *env, jobject thiz, jshortArray pcm_data, jint sample_count) {
    jshort *pcm = env->GetShortArrayElements(pcm_data, NULL);
    
    int ret = nade_feed_mic_frame((const int16_t *)pcm, sample_count);
    
    env->ReleaseShortArrayElements(pcm_data, pcm, JNI_ABORT);
    
    return ret;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_NadePlugin_nativeProcessRemoteInput(JNIEnv *env, jobject thiz, jshortArray pcm_data, jint sample_count) {
    jshort *pcm = env->GetShortArrayElements(pcm_data, NULL);
    
    int ret = nade_process_remote_input((const int16_t *)pcm, sample_count);
    
    env->ReleaseShortArrayElements(pcm_data, pcm, JNI_ABORT);
    
    return ret;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_NadePlugin_nativeGetModulatedOutput(JNIEnv *env, jobject thiz, jshortArray out_buffer, jint max_samples) {
    jshort *buffer = env->GetShortArrayElements(out_buffer, NULL);
    size_t samples_read = 0;
    
    int ret = nade_get_modulated_output((int16_t *)buffer, max_samples, &samples_read);
    
    env->ReleaseShortArrayElements(out_buffer, buffer, 0);
    
    return (ret == NADE_OK) ? (jint)samples_read : 0;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_NadePlugin_nativePullSpeakerFrame(JNIEnv *env, jobject thiz, jshortArray out_buffer, jint max_samples) {
    jshort *buffer = env->GetShortArrayElements(out_buffer, NULL);
    size_t samples_read = 0;
    
    int ret = nade_pull_speaker_frame((int16_t *)buffer, max_samples, &samples_read);
    
    env->ReleaseShortArrayElements(out_buffer, buffer, 0);
    
    return (ret == NADE_OK) ? (jint)samples_read : 0;
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_NadePlugin_nativeSetConfig(JNIEnv *env, jobject thiz, jstring config_json) {
    const char *config_str = env->GetStringUTFChars(config_json, NULL);
    
    int ret = nade_set_config(config_str);
    
    env->ReleaseStringUTFChars(config_json, config_str);
    
    return ret;
}

JNIEXPORT jstring JNICALL
Java_com_icing_nade_NadePlugin_nativeGetStatus(JNIEnv *env, jobject thiz) {
    char status_buf[1024];
    
    if (nade_get_status(status_buf, sizeof(status_buf)) == NADE_OK) {
        return env->NewStringUTF(status_buf);
    }
    
    return env->NewStringUTF("{}");
}

JNIEXPORT jint JNICALL
Java_com_icing_nade_NadePlugin_nativePingCapability(JNIEnv *env, jobject thiz, jstring peer_id) {
    const char *peer_id_str = env->GetStringUTFChars(peer_id, NULL);
    
    int ret = nade_ping_capability(peer_id_str);
    
    env->ReleaseStringUTFChars(peer_id, peer_id_str);
    
    return ret;
}

} // extern "C"
