
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Dart surface for the NADE audio transport plugin.
class Nade {
  static const MethodChannel _channel = MethodChannel('nade_flutter');

  static Completer<void>? _initializing;
  static bool _isInitialized = false;
  static bool _handlerBound = false;
  static void Function(Map<String, dynamic>)? _eventHandler;

  static Future<void> initialize({required Uint8List identityKeySeed, bool force = false}) async {
    if (_isInitialized && !force) {
      return;
    }
    if (_initializing != null) {
      return _initializing!.future;
    }
    _initializing = Completer<void>();
    if (!_handlerBound) {
      _channel.setMethodCallHandler(_handleCallbacks);
      _handlerBound = true;
    }
    await _channel.invokeMethod('initialize', {
      'identityKeySeed': identityKeySeed,
    });
    _isInitialized = true;
    _initializing?.complete();
    _initializing = null;
  }

  static Future<String> derivePublicKey(Uint8List seed) async {
    final result = await _channel.invokeMethod<String>('derivePublicKey', {
      'seed': seed,
    });
    if (result == null || result.isEmpty) {
      throw StateError('Failed to derive NADE public key');
    }
    return result;
  }

  static Future<bool> startAsServer({required String peerPublicKeyBase64}) async {
    await _waitForInit();
    final result = await _channel.invokeMethod<bool>('startServer', {
      'peerPublicKeyBase64': peerPublicKeyBase64,
    });
    return result ?? false;
  }

  static Future<bool> startAsClient({
    required String peerPublicKeyBase64,
    required String targetAddress,
  }) async {
    await _waitForInit();
    final result = await _channel.invokeMethod<bool>('startClient', {
      'peerPublicKeyBase64': peerPublicKeyBase64,
      'targetAddress': targetAddress,
    });
    return result ?? false;
  }

  static Future<void> stop() async {
    if (!_isInitialized) return;
    await _channel.invokeMethod('stop');
  }

  static Future<void> configure(Map<String, dynamic> cfg) async {
    await _waitForInit();
    await _channel.invokeMethod('configure', cfg);
  }

  static void setEventHandler(void Function(Map<String, dynamic>) handler) {
    _eventHandler = handler;
  }

  // -------------------------------------------------------------------------
  // 4-FSK Audio Transport Mode
  // When enabled, encrypted data is modulated to audio tones for transmission
  // over voice channels (phone calls, radios, walkie-talkies, etc.)

  /// Enable or disable 4-FSK audio transport mode.
  /// 
  /// When enabled:
  /// - Outgoing encrypted data is modulated to audio tones (1200/1600/2000/2400 Hz)
  /// - Incoming audio is demodulated back to encrypted data bytes
  /// 
  /// Use this for "audio over audio" transmission where you need to send
  /// encrypted data through a voice channel rather than a data channel.
  /// 
  /// Note: This reduces throughput to ~50 bytes/sec but allows transmission
  /// over any voice-capable medium.
  static Future<void> setFskMode(bool enabled) async {
    await _waitForInit();
    await _channel.invokeMethod('configure', {'fsk_mode': enabled});
  }

  // -------------------------------------------------------------------------
  // 4-FSK Modulation API
  // Converts encrypted data bytes <-> audio tones for "audio over audio" transport

  /// Enable or disable 4-FSK modulation.
  /// When enabled, NADE data is converted to audio tones (1200/1600/2000/2400 Hz)
  /// that can be transmitted over any voice channel (phone call, radio, etc.)
  static Future<bool> setFskEnabled(bool enabled) async {
    await _waitForInit();
    final result = await _channel.invokeMethod<bool>('fskSetEnabled', {
      'enabled': enabled,
    });
    return result ?? false;
  }

  /// Check if 4-FSK modulation is currently enabled.
  static Future<bool> isFskEnabled() async {
    await _waitForInit();
    final result = await _channel.invokeMethod<bool>('fskIsEnabled');
    return result ?? true;
  }

  /// Modulate data bytes into PCM audio samples.
  /// Each byte produces 320 PCM samples at 8kHz (4 symbols × 80 samples/symbol).
  /// @param data The encrypted data bytes to modulate
  /// @return Int16List of PCM audio samples representing the 4-FSK tones
  static Future<Int16List> fskModulate(Uint8List data) async {
    await _waitForInit();
    final result = await _channel.invokeMethod<Int16List>('fskModulate', {
      'data': data,
    });
    return result ?? Int16List(0);
  }

  /// Feed received PCM audio for demodulation.
  /// Call fskPullDemodulated() after to retrieve decoded bytes.
  /// @param pcm Received audio samples (8kHz, 16-bit mono)
  static Future<void> fskFeedAudio(Int16List pcm) async {
    await _waitForInit();
    await _channel.invokeMethod('fskFeedAudio', {
      'pcm': pcm,
    });
  }

  /// Pull demodulated bytes after feeding audio.
  /// @return Decoded data bytes from the received audio
  static Future<Uint8List> fskPullDemodulated() async {
    await _waitForInit();
    final result = await _channel.invokeMethod<Uint8List>('fskPullDemodulated');
    return result ?? Uint8List(0);
  }

  /// Calculate number of PCM samples needed to modulate given bytes.
  /// (320 samples per byte = 4 symbols × 80 samples/symbol at 8kHz)
  static int fskSamplesForBytes(int byteCount) {
    return byteCount * 4 * 80; // 320 samples per byte
  }

  static Future<void> _waitForInit() async {
    if (_isInitialized) return;
    if (_initializing != null) {
      await _initializing!.future;
      return;
    }
    throw StateError('Nade.initialize must be called before using the plugin');
  }

  static Future<void> _handleCallbacks(MethodCall call) async {
    if (call.method == 'event') {
      final handler = _eventHandler;
      if (handler != null && call.arguments is Map) {
        handler(Map<String, dynamic>.from(call.arguments as Map));
      }
    }
  }
}
