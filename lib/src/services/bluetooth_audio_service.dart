import 'package:flutter/services.dart';

class BluetoothAudioService {
  static const MethodChannel _channel = MethodChannel('bt_audio');
  static Future<dynamic> Function(MethodCall call)? _externalHandler;
  static void setMethodCallHandler(Future<dynamic> Function(MethodCall call) handler) {
    _externalHandler = handler;
    _channel.setMethodCallHandler((call) async {
      if (_externalHandler != null) {
        return _externalHandler!(call);
      }
      return null;
    });
  }
  static final BluetoothAudioService instance = BluetoothAudioService._();

  BluetoothAudioService._();

  Future<void> startServer({
    required bool decrypt,
    required bool encrypt,
    String? discoveryHint,
    required Map<String, dynamic> profile,
  }) async {
    await _channel.invokeMethod('startServer', {
      'decrypt': decrypt,
      'encrypt': encrypt,
      'profile': profile,
      if (discoveryHint != null && discoveryHint.isNotEmpty) 'discoveryHint': discoveryHint,
    });
  }

  Future<void> stop() async {
    await _channel.invokeMethod('stop');
  }
  
  Future<void> endCall() async {
    await _channel.invokeMethod('endCall');
  }

  Future<void> startScan() async {
    await _channel.invokeMethod('startScan');
  }

  Future<void> stopScan() async {
    await _channel.invokeMethod('stopScan');
  }

  Future<void> connectToDevice(
    String address, {
    required bool decrypt,
    required bool encrypt,
    required Map<String, dynamic> profile,
  }) async {
    await _channel.invokeMethod('startClient', {
      'macAddress': address,
      'decrypt': decrypt,
      'encrypt': encrypt,
      'profile': profile,
    });
  }

  Future<Map<String, String>> getLocalDeviceInfo() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('getLocalDeviceInfo');
    if (result == null) {
      return const {'name': '', 'address': ''};
    }
    return {
      'name': (result['name'] ?? '') as String,
      'address': (result['address'] ?? '') as String,
    };
  }
  
  Future<void> updateDecrypt(bool decrypt) async {
    try {
      await _channel.invokeMethod('setDecrypt', {'decrypt': decrypt});
    } catch (_) {}
  }

  Future<void> updateEncrypt(bool encrypt) async {
    try {
      await _channel.invokeMethod('setEncrypt', {'encrypt': encrypt});
    } catch (_) {}
  }

  Future<void> updateSpeaker(bool speaker) async {
    try {
      await _channel.invokeMethod('setSpeaker', {'speaker': speaker});
    } catch (_) {}
  }
}
