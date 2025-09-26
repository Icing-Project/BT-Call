import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/device.dart';
import '../services/bluetooth_audio_service.dart';

enum UXMessageType { info, warning, error }

class UXMessage {
  const UXMessage(this.text, {this.type = UXMessageType.info});

  final String text;
  final UXMessageType type;
}

class BluetoothProvider extends ChangeNotifier {
  final BluetoothAudioService _service = BluetoothAudioService.instance;

  List<Device> _devices = [];
  String _status = 'idle';
  bool _decryptEnabled = true;
  bool _encryptEnabled = true;
  final Set<String> _seen = {};
  final List<UXMessage> _messageQueue = [];
  bool _scanInProgress = false;
  bool _serverStarting = false;
  bool _serverActive = false;
  bool _isConnecting = false;
  
  // Connected device info
  Device? _connectedDevice;

  List<Device> get devices => _devices;
  String get status => _status;
  bool get decryptEnabled => _decryptEnabled;
  bool get encryptEnabled => _encryptEnabled;
  bool _speakerOn = false;
  bool get speakerOn => _speakerOn;
  Device? get connectedDevice => _connectedDevice;
  bool get isConnected => _status == 'connected' && _connectedDevice != null;
  bool get isScanInProgress => _scanInProgress;
  bool get isServerStarting => _serverStarting;
  bool get isServerActive => _serverActive;
  bool get isConnecting => _isConnecting;
  bool get hasPendingMessages => _messageQueue.isNotEmpty;
  bool get canStartServer => !_serverStarting && !_serverActive;
  bool get canStopServer => _serverActive || _serverStarting;
  bool get canStartScan => !_scanInProgress;
  bool get canStopScan => _scanInProgress;
  bool get canInitiateConnection => !_isConnecting;

  BluetoothProvider() {
    BluetoothAudioService.setMethodCallHandler(_handleNativeCall);
  }

  List<UXMessage> takeMessageBatch() {
    if (_messageQueue.isEmpty) return const [];
    final batch = List<UXMessage>.from(_messageQueue);
    _messageQueue.clear();
    return batch;
  }

  void _pushMessage(String message, {UXMessageType type = UXMessageType.info}) {
    _messageQueue.add(UXMessage(message, type: type));
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
        _status = 'connected';
        _isConnecting = false;
        _serverActive = true;
        _pushMessage('Connected to $name', type: UXMessageType.info);
        notifyListeners();
        break;
      case 'onCallEnded':
        // Handle when the remote device ends the call
        _status = 'call ended by remote';
        _connectedDevice = null;
        _isConnecting = false;
        _serverActive = false;
        _pushMessage('Call ended by remote device.', type: UXMessageType.warning);
        notifyListeners();
        break;
      case 'onStatus':
        _status = call.arguments as String;
        // Clear connected device if disconnected
        if (_status == 'stopped' || _status == 'disconnected' || _status.contains('Error')) {
          _connectedDevice = null;
        }
        final normalized = _status.toLowerCase();
        if (normalized.contains('connected')) {
          _isConnecting = false;
          _serverActive = true;
        }
        if (normalized.contains('disconnected') || normalized.contains('call ended')) {
          _isConnecting = false;
          _serverActive = false;
        }
        if (normalized.contains('scanning')) {
          _scanInProgress = true;
        }
        if (normalized.contains('scan stopped') || normalized.contains('scan cancelled')) {
          _scanInProgress = false;
        }
        if (normalized == 'stopped') {
          _serverActive = false;
          _serverStarting = false;
        }
        if (normalized.contains('permissions')) {
          _pushMessage('Permissions are required to continue.', type: UXMessageType.warning);
        }
        notifyListeners();
        break;
      case 'onError':
        _status = 'Error: ${call.arguments}';
        _isConnecting = false;
        _scanInProgress = false;
        _serverStarting = false;
        _serverActive = false;
        _pushMessage('Error: ${call.arguments}', type: UXMessageType.error);
        notifyListeners();
        break;
      default:
        break;
    }
    return null;
  }

  Future<void> startServer() async {
    if (!canStartServer) {
      _pushMessage('Server is already running or starting.', type: UXMessageType.info);
      notifyListeners();
      return;
    }
    _serverStarting = true;
    _status = 'starting server';
    _resetCallSettingsToDefaults();
    notifyListeners();
    final statuses = await [
      Permission.microphone,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();
    if (statuses.values.any((s) => !s.isGranted)) {
      _status = 'Permissions required';
      _serverStarting = false;
      _pushMessage('Server requires microphone and Bluetooth permissions.', type: UXMessageType.warning);
      notifyListeners();
      return;
    }
    try {
      await _service.startServer(decrypt: _decryptEnabled, encrypt: _encryptEnabled);
      _serverActive = true;
      _pushMessage('Server started. Waiting for incoming calls.');
    } on PlatformException catch (e) {
      _status = 'Error: ${e.message ?? 'server start failed'}';
      _pushMessage('Failed to start server: ${e.message ?? 'unknown error'}', type: UXMessageType.error);
    } catch (e) {
      _status = 'Error: $e';
      _pushMessage('Failed to start server: $e', type: UXMessageType.error);
    } finally {
      _serverStarting = false;
      notifyListeners();
    }
  }

  Future<void> stopServer() async {
    if (!canStopServer) {
      _pushMessage('Server is not running.', type: UXMessageType.info);
      notifyListeners();
      return;
    }
    _status = 'stopping server';
    notifyListeners();
    try {
      await _service.stop();
      _serverActive = false;
      _status = 'stopped';
      _pushMessage('Server stopped.');
    } on PlatformException catch (e) {
      _pushMessage('Failed to stop server: ${e.message ?? 'unknown error'}', type: UXMessageType.error);
    } catch (e) {
      _pushMessage('Failed to stop server: $e', type: UXMessageType.error);
    } finally {
      _serverStarting = false;
      notifyListeners();
    }
  }

  Future<void> startScan() async {
    if (!canStartScan) {
      _pushMessage('Scan already in progress.', type: UXMessageType.info);
      notifyListeners();
      return;
    }
    _scanInProgress = true;
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
      _scanInProgress = false;
      _pushMessage('Scanning requires Bluetooth and Location permissions.', type: UXMessageType.warning);
      notifyListeners();
      return;
    }
    try {
      await _service.startScan();
      _pushMessage('Scanning for nearby devices...');
    } on PlatformException catch (e) {
      _status = 'scan failed';
      _scanInProgress = false;
      _pushMessage('Unable to start scan: ${e.message ?? 'unknown error'}', type: UXMessageType.error);
    } catch (e) {
      _status = 'scan failed';
      _scanInProgress = false;
      _pushMessage('Unable to start scan: $e', type: UXMessageType.error);
    } finally {
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    if (!canStopScan) {
      _pushMessage('No active scan to stop.', type: UXMessageType.info);
      notifyListeners();
      return;
    }
    try {
      await _service.stopScan();
      _status = 'scan stopped';
      _pushMessage('Scan stopped.');
    } on PlatformException catch (e) {
      _pushMessage('Failed to stop scan: ${e.message ?? 'unknown error'}', type: UXMessageType.error);
    } catch (e) {
      _pushMessage('Failed to stop scan: $e', type: UXMessageType.error);
    } finally {
      _scanInProgress = false;
      notifyListeners();
    }
  }

  Future<void> connectToDevice(String address) async {
    if (!canInitiateConnection) {
      _pushMessage('Already connecting to a device.', type: UXMessageType.info);
      notifyListeners();
      return;
    }
    _isConnecting = true;
    _status = 'connecting';
    _resetCallSettingsToDefaults();
    // Find the device by address to store connected device info
    final device = _devices.firstWhere(
      (d) => d.address == address, 
      orElse: () => Device(name: 'Unknown Device', address: address)
    );
    _connectedDevice = device;
    notifyListeners();
    try {
      await _service.connectToDevice(address, decrypt: _decryptEnabled, encrypt: _encryptEnabled);
      _pushMessage('Connecting to ${device.name}...');
    } on PlatformException catch (e) {
      _status = 'connection failed';
      _isConnecting = false;
      _connectedDevice = null;
      _pushMessage('Failed to connect: ${e.message ?? 'unknown error'}', type: UXMessageType.error);
      notifyListeners();
    } catch (e) {
      _status = 'connection failed';
      _isConnecting = false;
      _connectedDevice = null;
      _pushMessage('Failed to connect: $e', type: UXMessageType.error);
      notifyListeners();
    }
  }
  
  Future<void> disconnect() async {
    if (_connectedDevice == null) {
      _pushMessage('No active connection to disconnect.', type: UXMessageType.info);
      notifyListeners();
      return;
    }
    _status = 'disconnecting';
    notifyListeners();
    try {
      await _service.stop();
      _connectedDevice = null;
      _serverActive = false;
      _status = 'disconnected';
      _pushMessage('Disconnected.');
    } on PlatformException catch (e) {
      _pushMessage('Failed to disconnect: ${e.message ?? 'unknown error'}', type: UXMessageType.error);
    } catch (e) {
      _pushMessage('Failed to disconnect: $e', type: UXMessageType.error);
    } finally {
      _isConnecting = false;
      notifyListeners();
    }
  }
  
  Future<void> endCall() async {
    if (_connectedDevice == null) {
      _pushMessage('No active call to end.', type: UXMessageType.info);
      notifyListeners();
      return;
    }
    _status = 'ending call';
    _connectedDevice = null; // Disconnect immediately
    notifyListeners();
    try {
      await _service.endCall();
      _status = 'call ended';
      _pushMessage('Call ended.');
    } on PlatformException catch (e) {
      _status = 'Error: ${e.message ?? 'end call failed'}';
      _pushMessage('Failed to end call: ${e.message ?? 'unknown error'}', type: UXMessageType.error);
    } catch (e) {
      _status = 'Error: $e';
      _pushMessage('Failed to end call: $e', type: UXMessageType.error);
    } finally {
      _serverActive = false;
      _isConnecting = false;
      notifyListeners();
    }
  }

  /// Reset call settings to their default values when starting a new call
  void _resetCallSettingsToDefaults() {
    _decryptEnabled = true;   // Decryption enabled by default
    _encryptEnabled = true;   // Encryption enabled by default  
    _speakerOn = false;       // Speaker disabled by default
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

  void toggleSpeaker(bool value) {
    _speakerOn = value;
    _service.updateSpeaker(value);
    notifyListeners();
  }
}