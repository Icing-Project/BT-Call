import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/device.dart';
import '../services/bluetooth_audio_service.dart';

class BluetoothProvider extends ChangeNotifier {
  final BluetoothAudioService _service = BluetoothAudioService.instance;

  List<Device> _devices = [];
  String _status = 'idle';
  bool _decryptEnabled = true;
  final Set<String> _seen = {};

  List<Device> get devices => _devices;
  String get status => _status;
  bool get decryptEnabled => _decryptEnabled;

  BluetoothProvider() {
    BluetoothAudioService.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onDeviceFound':
        final args = call.arguments as Map;
        final name = args['name'] as String;
        final address = args['address'] as String;
        if (!_seen.contains(address)) {
          _seen.add(address);
          _devices.add(Device(name: name, address: address));
          notifyListeners();
        }
        break;
      case 'onStatus':
        _status = call.arguments as String;
        notifyListeners();
        break;
      case 'onError':
        _status = 'Error: ${call.arguments}';
        notifyListeners();
        break;
      default:
        break;
    }
    return null;
  }

  Future<void> startServer() async {
    _status = 'starting server';
    notifyListeners();
    final statuses = await [
      Permission.microphone,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();
    if (statuses.values.any((s) => !s.isGranted)) {
      _status = 'Permissions required';
      notifyListeners();
      return;
    }
    await _service.startServer(decrypt: _decryptEnabled);
  }

  Future<void> stopServer() async {
    await _service.stop();
    _status = 'stopped';
    notifyListeners();
  }

  Future<void> startScan() async {
    _status = 'scanning';
    _devices.clear();
    _seen.clear();
    notifyListeners();
    final statuses = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    if (statuses.values.any((s) => !s.isGranted)) {
      _status = 'Permissions required';
      notifyListeners();
      return;
    }
    await _service.startScan();
  }

  Future<void> stopScan() async {
    await _service.stopScan();
    _status = 'scan stopped';
    notifyListeners();
  }

  Future<void> connectToDevice(String address) async {
    _status = 'connecting';
    notifyListeners();
    await _service.connectToDevice(address, decrypt: _decryptEnabled);
  }

  void toggleDecrypt(bool value) {
    _decryptEnabled = value;
    // Notify native layer to update decryption mode dynamically
    _service.updateDecrypt(value);
    notifyListeners();
  }
}