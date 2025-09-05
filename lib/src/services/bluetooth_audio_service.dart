import 'package:flutter/services.dart';

class BluetoothAudioService {
  static const MethodChannel _channel = MethodChannel('bt_audio');

  static void setMethodCallHandler(Future<dynamic> Function(MethodCall call) handler) {
    _channel.setMethodCallHandler(handler);
  }

  Future<void> startServer({required bool decrypt}) async {
    await _channel.invokeMethod('startServer', {'decrypt': decrypt});
  }

  Future<void> stop() async {
    await _channel.invokeMethod('stop');
  }

  Future<void> startScan() async {
    await _channel.invokeMethod('startScan');
  }

  Future<void> stopScan() async {
    await _channel.invokeMethod('stopScan');
  }

  Future<void> connectToDevice(String address, {required bool decrypt}) async {
    await _channel.invokeMethod('startClient', {'macAddress': address, 'decrypt': decrypt});
  }
  /// Update decryption mode on the native side dynamically
  Future<void> updateDecrypt(bool decrypt) async {
    // Toggle decryption mid-stream on native side
    try {
      await _channel.invokeMethod('setDecrypt', {'decrypt': decrypt});
    } catch (_) {
      // If native doesn't support, ignore
    }
  }
}
