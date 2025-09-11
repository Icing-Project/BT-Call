import 'dart:async';
import 'dart:typed_data';
// Removed flutter_sound integration; audio I/O handled natively
import 'package:flutter/services.dart';
import 'four_fsk_service.dart';

class BluetoothAudioService {
  static const MethodChannel _channel = MethodChannel('bt_audio');
  static final _decodedController = StreamController<Uint8List>.broadcast();
  final FourFskService fsk;

  BluetoothAudioService({required this.fsk});

  static Future<dynamic> Function(MethodCall call)? _externalHandler;
  static void setMethodCallHandler(Future<dynamic> Function(MethodCall call) handler) {
    _externalHandler = handler;
    _channel.setMethodCallHandler(_internalHandler);
  }

  /// Stream of demodulated payloads from incoming 4-FSK frames.
  Stream<Uint8List> get onDecodedData => _decodedController.stream;

  static Future<dynamic> _internalHandler(MethodCall call) async {
    if (call.method == 'onAudioFrame') {
      final Uint8List pcm = call.arguments;
      // demodulate into raw bytes
      // note: needs instance; assume single global instance set before use
      final svc = _instance;
      if (svc != null) {
        final data = svc.fsk.demodulate(pcm);
        _decodedController.add(data);
      }
      return;
    }
    if (_externalHandler != null) {
      return _externalHandler!(call);
    }
  }

  static BluetoothAudioService? _instance;
  /// Global singleton after initialize()
  static BluetoothAudioService get instance {
    if (_instance == null) throw StateError('BluetoothAudioService not initialized');
    return _instance!;
  }
  /// Initialize audio service with a FourFskService modem.
  static void initialize(FourFskService modem) {
    _instance = BluetoothAudioService(fsk: modem);
  }

  Future<void> startServer({required bool decrypt}) async {
    await _channel.invokeMethod('startServer', {'decrypt': decrypt});
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

  Future<void> connectToDevice(String address, {required bool decrypt}) async {
    await _channel.invokeMethod('startClient', {'macAddress': address, 'decrypt': decrypt});
  }
  
  /// Send a payload over 4-FSK: modulate then invoke native send.
  Future<void> sendData(Uint8List data) async {
    final svc = _instance!;
    final pcm = svc.fsk.modulate(data);
    await _channel.invokeMethod('sendData', pcm);
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

    /// Start a 4-FSK call: native code captures mic, streams frames to Dart for demodulation,
    /// and sends modulated data back for transmission.
    Future<void> startCall() async {
      await _channel.invokeMethod('startCall');
    }

    /// Stop the ongoing 4-FSK call.
    Future<void> stopCall() async {
      await _channel.invokeMethod('stopCall');
    }
}
