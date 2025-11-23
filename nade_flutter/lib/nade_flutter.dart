
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
