import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:nade_flutter/nade_flutter.dart';

import '../models/contact.dart';
import '../models/device.dart';
import '../repositories/share_profile_repository.dart';
import '../services/asymmetric_crypto_service.dart';
import '../services/bluetooth_audio_service.dart';
import 'contacts_provider.dart';

enum UXMessageType { info, warning, error }

class UXMessage {
  const UXMessage(this.text, {this.type = UXMessageType.info});

  final String text;
  final UXMessageType type;
}

enum _CallRole { none, server, client }

class BluetoothProvider extends ChangeNotifier {
  final BluetoothAudioService _service = BluetoothAudioService.instance;
  final ShareProfileRepository _shareProfileRepository = ShareProfileRepository();
  final AsymmetricCryptoService _cryptoService = AsymmetricCryptoService();

  Uint8List? _identitySeed;
  String? _identityAlias;
  Future<void>? _nadeInitFuture;
  bool _nadeReady = false;
  bool _nadeSessionActive = false;
  bool _nadeEverInitialized = false;
  _CallRole _callRole = _CallRole.none;

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
  String? _cachedDiscoveryHint;
  ContactsProvider? _contactsProvider;
  final Map<String, String> _hintByAddress = {};
  String _sessionPeerPublicKey = '';
  
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
    Nade.setEventHandler(_handleNadeEvent);
  }

  void attachContactsProvider(ContactsProvider provider) {
    _contactsProvider = provider;
  }

  void refreshDiscoveryHint() {
    _cachedDiscoveryHint = null;
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
        final hint = (args['hint'] as String? ?? '').toUpperCase();
        if (!_seen.contains(address)) {
          _seen.add(address);
          final device = Device(name: name, address: address, discoveryHint: hint);
          _devices.add(device);
          if (hint.isNotEmpty) {
            _hintByAddress[address.toUpperCase()] = hint;
            _maybeUpdateContactFromDiscovery(device);
          }
          notifyListeners();
        }
        break;
      case 'onDeviceConnected':
        print('BluetoothProvider: onDeviceConnected called'); // DEBUG LOG
        // Handle when a device connects (from either client or server side)
        final args = call.arguments as Map;
        final address = args['address'] as String;
        final existingHint = _hintByAddress[address.toUpperCase()] ?? '';
        final hintFromArgs = (args['hint'] as String? ?? '').toUpperCase();
        final profile = (args['profile'] as Map?)?.cast<String, dynamic>();
        String remoteHint = (profile?['discoveryHint'] as String? ?? '').toUpperCase();
        if (remoteHint.isEmpty) {
          remoteHint = hintFromArgs.isNotEmpty ? hintFromArgs : existingHint;
        }
        final remoteName = (profile?['displayName'] as String? ?? args['name'] as String).trim();
        final deviceName = remoteName.isNotEmpty ? remoteName : args['name'] as String;
        if (remoteHint.isNotEmpty) {
          _hintByAddress[address.toUpperCase()] = remoteHint;
        }
        _connectedDevice = Device(name: deviceName, address: address, discoveryHint: remoteHint);
        if (profile != null) {
          _storePeerProfile(_connectedDevice!, profile);
        } else if (remoteHint.isNotEmpty) {
          _maybeUpdateContactFromDiscovery(_connectedDevice!);
        }
        _status = 'connected';
        _isConnecting = false;
        _serverActive = true;
        _pushMessage('Connected to $deviceName', type: UXMessageType.info);
        await _startNadeForConnectedDevice(_connectedDevice!);
        notifyListeners();
        break;
      case 'onCallEnded':
        // Handle when the remote device ends the call
        _status = 'call ended by remote';
        _connectedDevice = null;
        _isConnecting = false;
        _serverActive = false;
        await _stopNadeSession();
        _pushMessage('Call ended by remote device.', type: UXMessageType.warning);
        notifyListeners();
        break;
      case 'onStatus':
        _status = call.arguments as String;
        // Clear connected device if disconnected
        if (_status == 'stopped' || _status == 'disconnected' || _status.contains('Error')) {
          _connectedDevice = null;
          await _stopNadeSession();
        }
        final normalized = _status.toLowerCase();
        if (normalized.contains('connected')) {
          _isConnecting = false;
          _serverActive = true;
        }
        if (normalized.contains('disconnected') || normalized.contains('call ended')) {
          _isConnecting = false;
          _serverActive = false;
          await _stopNadeSession();
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
        await _stopNadeSession();
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

    // Initialize NADE before setting role to avoid race condition where
    // initialization resets the role to 'none'.
    await _ensureNadeInitialized();
    _callRole = _CallRole.server;

    final statuses = await [
      Permission.microphone,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();
    if (statuses.values.any((s) => !s.isGranted)) {
      _status = 'Permissions required';
      _serverStarting = false;
       _callRole = _CallRole.none;
      _pushMessage('Server requires microphone and Bluetooth permissions.', type: UXMessageType.warning);
      notifyListeners();
      return;
    }
    Map<String, String>? profile;
    try {
      profile = await _buildLocalTransportProfile();
    } catch (e) {
      _status = 'key required';
      _serverStarting = false;
      _callRole = _CallRole.none;
      _pushMessage(e.toString(), type: UXMessageType.error);
      notifyListeners();
      return;
    }
    final hint = profile['discoveryHint'] ?? '';
    try {
      print('BluetoothProvider: Starting server with hint: $hint, encrypt: $_encryptEnabled, decrypt: $_decryptEnabled !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'); // DEBUG LOG
      await _service.startServer(
        decrypt: _decryptEnabled,
        encrypt: _encryptEnabled,
        discoveryHint: hint,
        profile: Map<String, dynamic>.from(profile),
      );
      _serverActive = true;
      _pushMessage('Server started. Waiting for incoming calls.');
    } on PlatformException catch (e) {
      _status = 'Error: ${e.message ?? 'server start failed'}';
      _callRole = _CallRole.none;
      _pushMessage('Failed to start server: ${e.message ?? 'unknown error'}', type: UXMessageType.error);
    } catch (e) {
      _status = 'Error: $e';
      _callRole = _CallRole.none;
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
      await _stopNadeSession();
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
    _hintByAddress.clear();
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
    
    // Initialize NADE before setting role to avoid race condition
    await _ensureNadeInitialized();
    _callRole = _CallRole.client;

    // Request permissions for Client role as well
    final statuses = await [
      Permission.microphone,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();
    
    if (statuses.values.any((s) => !s.isGranted)) {
      _status = 'Permissions required';
      _isConnecting = false;
      _callRole = _CallRole.none;
      _pushMessage('Call requires microphone and Bluetooth permissions.', type: UXMessageType.warning);
      notifyListeners();
      return;
    }

    // Find the device by address to store connected device info
    final device = _devices.firstWhere(
      (d) => d.address == address, 
      orElse: () {
        final hint = _hintByAddress[address.toUpperCase()] ?? '';
        return Device(name: 'Unknown Device', address: address, discoveryHint: hint);
      },
    );
    _connectedDevice = device;
    notifyListeners();
    Map<String, String>? profile;
    try {
      profile = await _buildLocalTransportProfile();
    } catch (e) {
      _status = 'key required';
      _isConnecting = false;
      _callRole = _CallRole.none;
      _pushMessage(e.toString(), type: UXMessageType.error);
      notifyListeners();
      return;
    }
    try {
      await _service.connectToDevice(
        address,
        decrypt: _decryptEnabled,
        encrypt: _encryptEnabled,
        profile: Map<String, dynamic>.from(profile),
      );
      _pushMessage('Connecting to ${device.name}...');
    } on PlatformException catch (e) {
      _status = 'connection failed';
      _isConnecting = false;
      _connectedDevice = null;
      _callRole = _CallRole.none;
      _pushMessage('Failed to connect: ${e.message ?? 'unknown error'}', type: UXMessageType.error);
      notifyListeners();
    } catch (e) {
      _status = 'connection failed';
      _isConnecting = false;
      _connectedDevice = null;
      _callRole = _CallRole.none;
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
      await _stopNadeSession();
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
      await _stopNadeSession();
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
    _decryptEnabled = true;   // Encryption/decryption required by default
    _encryptEnabled = true;   // Encryption/decryption required by default  
    _speakerOn = false;       // Speaker disabled by default
    _sessionPeerPublicKey = '';
  }

  Future<Map<String, String>> _buildLocalTransportProfile() async {
    final discoveryHint = await _ensureDiscoveryHint();
    var displayName = (await _shareProfileRepository.loadDisplayName())?.trim();
    
    // Fall back to local Bluetooth device name if no display name is saved
    if (displayName == null || displayName.isEmpty) {
      try {
        final info = await _service.getLocalDeviceInfo();
        displayName = info['name']?.trim();
      } catch (_) {
        // Ignore errors fetching device name
      }
    }
    
    // Ensure we have a valid key (this will auto-create one if needed)
    final savedAlias = await _shareProfileRepository.loadKeyAlias();
    final validAlias = await _cryptoService.ensureValidKey(savedAlias);
    
    late final String publicKey;
    try {
      publicKey = (await _cryptoService.deriveNadePublicKey(validAlias)).trim();
    } catch (e) {
      throw StateError('No key material available. Generate a key pair in Contacts > Share. ($e)');
    }
    if (!_isValidNadeKey(publicKey)) {
      throw StateError('Primary call key is invalid. Regenerate your key pair.');
    }
    return {
      'discoveryHint': discoveryHint,
      'displayName': (displayName != null && displayName.isNotEmpty) ? displayName : 'Unknown',
      'publicKey': publicKey,
    };
  }

  Future<String> _ensureDiscoveryHint() async {
    if (_cachedDiscoveryHint != null && _cachedDiscoveryHint!.isNotEmpty) {
      return _cachedDiscoveryHint!;
    }
    final hint = (await _shareProfileRepository.ensureDiscoveryHint()).toUpperCase();
    _cachedDiscoveryHint = hint;
    return hint;
  }

  Future<void> _ensureNadeInitialized() async {
    final savedAlias = await _shareProfileRepository.loadKeyAlias();
    // Ensure we have a valid key, creating one if necessary
    final validAlias = await _cryptoService.ensureValidKey(savedAlias);
    
    if (_identityAlias != validAlias) {
      await _stopNadeSession();
      _identityAlias = validAlias;
      // Save the valid alias if it changed
      if (savedAlias != validAlias) {
        await _shareProfileRepository.saveKeyAlias(validAlias);
      }
      _identitySeed = null;
      _nadeReady = false;
      _nadeInitFuture = null;
    }
    if (_nadeReady) {
      return;
    }
    _nadeInitFuture ??= () async {
      final seed = await _loadIdentitySeed(validAlias);
      await Nade.initialize(identityKeySeed: seed, force: _nadeEverInitialized);
      _nadeEverInitialized = true;
      _nadeReady = true;
      
      // Enable 4-FSK audio transport mode
      // This modulates encrypted data into audio tones (1200/1600/2000/2400 Hz)
      // for transmission over voice channels
      await Nade.setFskMode(true);
    }();
    await _nadeInitFuture;
  }

  Future<Uint8List> _loadIdentitySeed(String alias) async {
    if (_identitySeed != null && _identityAlias == alias) {
      return _identitySeed!;
    }
    final seed = await _cryptoService.deriveNadeSeed(alias);
    _identitySeed = seed;
    return seed;
  }

  Future<void> _startNadeForConnectedDevice(Device device) async {
    print('BluetoothProvider: _startNadeForConnectedDevice called for ${device.name}'); // DEBUG LOG
    if (_callRole == _CallRole.none) {
      print('BluetoothProvider: Call role is NONE, aborting NADE start'); // DEBUG LOG
      return;
    }
    try {
      await _ensureNadeInitialized();
      final peerKey = _extractPeerKey(device);
      print('BluetoothProvider: Extracted peer key: ${peerKey.isNotEmpty ? "FOUND" : "EMPTY"}'); // DEBUG LOG
      
      if (!_isValidNadeKey(peerKey)) {
        print('BluetoothProvider: Invalid peer key, stopping session'); // DEBUG LOG
        _status = 'missing peer key';
        _pushMessage(
          'Secure profile exchange failed. Ensure both devices shared codes before calling.',
          type: UXMessageType.error,
        );
        await _service.stop();
        await _stopNadeSession();
        notifyListeners();
        return;
      }
      await _applyNadeConfig();
      bool started;
      if (_callRole == _CallRole.server) {
        print('BluetoothProvider: Starting NADE as SERVER'); // DEBUG LOG
        started = await Nade.startAsServer(peerPublicKeyBase64: peerKey);
      } else {
        print('BluetoothProvider: Starting NADE as CLIENT'); // DEBUG LOG
        started = await Nade.startAsClient(
          peerPublicKeyBase64: peerKey,
          targetAddress: device.address,
        );
      }
      print('BluetoothProvider: NADE start result: $started'); // DEBUG LOG
      if (started) {
        _nadeSessionActive = true;
      } else {
        _pushMessage('Unable to start secure audio session.', type: UXMessageType.error);
      }
    } catch (e) {
      print('BluetoothProvider: Audio initialization failed: $e'); // DEBUG LOG
      _pushMessage('Audio initialization failed: $e', type: UXMessageType.error);
    }
  }

  bool _isValidNadeKey(String key) {
    if (key.trim().isEmpty) {
      return false;
    }
    try {
      final decoded = base64Decode(key.trim());
      return decoded.length == 32;
    } catch (_) {
      return false;
    }
  }

  String _extractPeerKey(Device device) {
    if (_sessionPeerPublicKey.isNotEmpty) {
      return _sessionPeerPublicKey.trim();
    }
    final hint = device.discoveryHint.toUpperCase();
    if (hint.isNotEmpty) {
      final contact = _contactsProvider?.contactForDiscoveryHint(hint);
      if (contact != null && contact.publicKey.isNotEmpty) {
        return contact.publicKey.trim();
      }
    }
    return '';
  }

  Future<void> _stopNadeSession() async {
    final shouldInvokeStop = _nadeSessionActive || _nadeEverInitialized;
    if (shouldInvokeStop) {
      try {
        await Nade.stop();
      } catch (_) {
        // ignore – stopping twice is safe
      }
    }
    _nadeSessionActive = false;
    _callRole = _CallRole.none;
    _sessionPeerPublicKey = '';
  }

  Future<void> _applyNadeConfig() async {
    if (!_nadeReady) return;
    await Nade.configure({
      'encrypt': _encryptEnabled,
      'decrypt': _decryptEnabled,
      'speaker': _speakerOn,
    });
  }

  void _handleNadeEvent(Map<String, dynamic> payload) {
    final type = payload['type'];
    if (type == 'state') {
      final value = payload['value']?.toString();
      if (value == 'remote_hangup') {
        _status = 'call ended by remote';
        _connectedDevice = null;
        _isConnecting = false;
        _serverActive = false;
        _nadeSessionActive = false;
        _callRole = _CallRole.none;
        _sessionPeerPublicKey = '';
        _pushMessage('Call ended by remote device.', type: UXMessageType.warning);
        notifyListeners();
        return;
      }
      if (value == 'stopped' || value == 'transport_detached' || value == 'link_closed') {
        _nadeSessionActive = false;
        _callRole = _CallRole.none;
      }
      notifyListeners();
      return;
    }
    if (type == 'error') {
      final message = payload['message']?.toString() ?? 'Unknown audio error';
      _pushMessage('Audio error: $message', type: UXMessageType.error);
      notifyListeners();
    }
  }

  void _maybeUpdateContactFromDiscovery(Device device) {
    final provider = _contactsProvider;
    final hint = device.discoveryHint.toUpperCase();
    if (provider == null || hint.isEmpty) {
      return;
    }
    provider.markContactSeenByHint(
      discoveryHint: hint,
      deviceName: device.name,
    );
  }

  void _storePeerProfile(Device device, Map<String, dynamic> profile) {
    final normalizedHint = (profile['discoveryHint'] as String? ?? device.discoveryHint).toUpperCase();
    final publicKey = (profile['publicKey'] as String? ?? '').trim();
    final displayName = (profile['displayName'] as String? ?? device.name).trim();
    if (normalizedHint.isNotEmpty) {
      _hintByAddress[device.address.toUpperCase()] = normalizedHint;
    }
    if (_isValidNadeKey(publicKey)) {
      _sessionPeerPublicKey = publicKey.trim();
    }
    final provider = _contactsProvider;
    if (provider != null && normalizedHint.isNotEmpty && _isValidNadeKey(publicKey)) {
      final contact = Contact(
        name: displayName.isNotEmpty ? displayName : device.name,
        publicKey: publicKey,
        discoveryHint: normalizedHint,
        createdAt: DateTime.now(),
        lastKnownDeviceName: device.name,
      );
      unawaited(provider.addContact(contact));
    }
  }

  void toggleDecrypt(bool value) {
    _decryptEnabled = value;
    // Notify native layer to update decryption mode dynamically
    _service.updateDecrypt(value);
    unawaited(_applyNadeConfig());
    notifyListeners();
  }
  
  void toggleEncrypt(bool value) {
    _encryptEnabled = value;
    // Notify native layer to update encryption mode dynamically
    _service.updateEncrypt(value);
    unawaited(_applyNadeConfig());
    notifyListeners();
  }

  void toggleSpeaker(bool value) {
    _speakerOn = value;
    _service.updateSpeaker(value);
    unawaited(_applyNadeConfig());
    notifyListeners();
  }
}