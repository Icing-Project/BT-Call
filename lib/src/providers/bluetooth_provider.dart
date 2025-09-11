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
  bool _encryptEnabled = true;
  final Set<String> _seen = {};
  
  // Connected device info
  Device? _connectedDevice;

  List<Device> get devices => _devices;
  String get status => _status;
  bool get decryptEnabled => _decryptEnabled;
  bool get encryptEnabled => _encryptEnabled;
  Device? get connectedDevice => _connectedDevice;
  bool get isConnected => _status == 'connected' && _connectedDevice != null;

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
      case 'onDeviceConnected':
        // Handle when a device connects (from either client or server side)
        final args = call.arguments as Map;
        final name = args['name'] as String;
        final address = args['address'] as String;
        _connectedDevice = Device(name: name, address: address);
        notifyListeners();
        break;
      case 'onCallEnded':
        // Handle when the remote device ends the call
        _status = 'call ended by remote';
        _connectedDevice = null;
        notifyListeners();
        break;
      case 'onStatus':
        _status = call.arguments as String;
        // Clear connected device if disconnected
        if (_status == 'stopped' || _status == 'disconnected' || _status.contains('Error')) {
          _connectedDevice = null;
        }
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
    await _service.startServer(decrypt: _decryptEnabled, encrypt: _encryptEnabled);
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
    // Find the device by address to store connected device info
    final device = _devices.firstWhere(
      (d) => d.address == address, 
      orElse: () => Device(name: 'Unknown Device', address: address)
    );
    _connectedDevice = device;
    notifyListeners();
    await _service.connectToDevice(address, decrypt: _decryptEnabled, encrypt: _encryptEnabled);
  }
  
  Future<void> disconnect() async {
    _status = 'disconnecting';
    notifyListeners();
    await _service.stop();
    _connectedDevice = null;
    _status = 'disconnected';
    notifyListeners();
  }
  
  Future<void> endCall() async {
    _status = 'ending call';
    _connectedDevice = null; // Disconnect immediately
    notifyListeners();
    await _service.endCall();
    _status = 'call ended';
    notifyListeners();
  }

  void toggleDecrypt(bool value) {
    _decryptEnabled = value;
    // Notify native layer to update decryption mode dynamically
    _service.updateDecrypt(value);
    notifyListeners();
  }
  
  void toggleEncrypt(bool value) {
    _encryptEnabled = value;
    // Notify native layer to update encryption mode dynamically
    _service.updateEncrypt(value);
    notifyListeners();
  }
}