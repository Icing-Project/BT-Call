import 'dart:async';
import 'package:flutter/services.dart';

/// NADE (Noise-encrypted Audio Data Exchange) Flutter Plugin
/// 
/// Provides end-to-end encrypted voice calls over Bluetooth using:
/// - Noise XK handshake for secure key exchange
/// - Codec2 voice compression
/// - Reed-Solomon FEC for error resilience
/// - ChaCha20-Poly1305 AEAD encryption
/// - 4-FSK modulation for audio channel transmission

class Nade {
  static const MethodChannel _channel = MethodChannel('nade_flutter/methods');
  static const EventChannel _events = EventChannel('nade_flutter/events');
  
  static StreamSubscription? _eventSubscription;
  static void Function(NadeEvent)? _eventHandler;
  
  static bool _initialized = false;

  /// Initialize NADE core with identity keypair.
  /// Must be called once at app startup before any other operations.
  /// 
  /// [identityKeyPairPem] - PEM-encoded keypair for Noise protocol
  /// [config] - Optional configuration (uses defaults if not provided)
  static Future<void> initialize({
    required String identityKeyPairPem,
    NadeConfig? config,
  }) async {
    if (_initialized) {
      throw StateError('NADE already initialized');
    }
    
    await _channel.invokeMethod('initialize', {
      'keyPem': identityKeyPairPem,
      'config': config?.toJson(),
    });
    
    _initialized = true;
  }

  /// Start a NADE-enabled call with a peer.
  /// 
  /// [peerId] - Identifier for remote party (phone number, device ID)
  /// [transport] - Transport type: "bluetooth", "audio_loopback", "wasapi", "sco"
  /// 
  /// Returns true if call started successfully, false otherwise.
  static Future<bool> startCall({
    required String peerId,
    required String transport,
  }) async {
    _ensureInitialized();
    
    final result = await _channel.invokeMethod<bool>('startCall', {
      'peerId': peerId,
      'transport': transport,
    });
    
    return result ?? false;
  }

  /// Stop the current NADE call.
  static Future<void> stopCall() async {
    _ensureInitialized();
    await _channel.invokeMethod('stopCall');
  }

  /// Check if a remote peer supports NADE protocol.
  /// This sends a capability ping over the audio channel.
  /// 
  /// Returns true if peer is NADE-capable, false otherwise.
  static Future<bool> isPeerNadeCapable(String peerId) async {
    _ensureInitialized();
    
    final result = await _channel.invokeMethod<bool>('isPeerNadeCapable', {
      'peerId': peerId,
    });
    
    return result ?? false;
  }

  /// Configure NADE parameters (can be called before or after initialization).
  /// 
  /// [config] - Configuration object with tuning parameters
  static Future<void> configure(NadeConfig config) async {
    await _channel.invokeMethod('configure', config.toJson());
  }

  /// Get current NADE status and statistics.
  /// 
  /// Returns a map with status information including:
  /// - state, handshakeComplete, fecCorrections, symbolErrors, etc.
  static Future<Map<String, dynamic>> getStatus() async {
    _ensureInitialized();
    
    final result = await _channel.invokeMapMethod<String, dynamic>('getStatus');
    return result ?? {};
  }

  /// Set event handler for NADE events.
  /// Events include handshake progress, errors, FEC stats, etc.
  /// 
  /// [handler] - Callback function that receives NadeEvent objects
  static void setEventHandler(void Function(NadeEvent) handler) {
    _eventHandler = handler;
    
    _eventSubscription?.cancel();
    _eventSubscription = _events.receiveBroadcastStream().listen((dynamic event) {
      if (_eventHandler != null && event is Map) {
        final nadeEvent = NadeEvent.fromMap(Map<String, dynamic>.from(event));
        _eventHandler!(nadeEvent);
      }
    });
  }

  /// Remove event handler and stop listening to events.
  static void removeEventHandler() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _eventHandler = null;
  }

  /// Shutdown NADE core and release all resources.
  static Future<void> shutdown() async {
    if (!_initialized) return;
    
    removeEventHandler();
    await _channel.invokeMethod('shutdown');
    _initialized = false;
  }

  static void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('NADE not initialized. Call Nade.initialize() first.');
    }
  }
}

/// NADE configuration parameters
class NadeConfig {
  /// Sample rate in Hz (default: 16000)
  final int sampleRate;
  
  /// Symbol rate for FSK modulation in baud (default: 100)
  final double symbolRate;
  
  /// Four frequencies for 4-FSK in Hz (default: [600, 900, 1200, 1500])
  final List<int> frequencies;
  
  /// FEC strength (RS erasure count, default: 32 for RS(255,223))
  final int fecStrength;
  
  /// Codec2 mode: 3200, 2400, 1600, 1400, 1300, 1200, 700C (default: 1400)
  final int codecMode;
  
  /// Enable debug logging (default: false)
  final bool debugLogging;
  
  /// Enable raw symbol buffer logging to file (default: false)
  final bool logSymbols;
  
  /// Handshake timeout in milliseconds (default: 10000)
  final int handshakeTimeoutMs;
  
  /// Maximum handshake retries (default: 5)
  final int maxHandshakeRetries;

  const NadeConfig({
    this.sampleRate = 16000,
    this.symbolRate = 100.0,
    this.frequencies = const [600, 900, 1200, 1500],
    this.fecStrength = 32,
    this.codecMode = 1400,
    this.debugLogging = false,
    this.logSymbols = false,
    this.handshakeTimeoutMs = 10000,
    this.maxHandshakeRetries = 5,
  });

  Map<String, dynamic> toJson() => {
    'sampleRate': sampleRate,
    'symbolRate': symbolRate,
    'frequencies': frequencies,
    'fecStrength': fecStrength,
    'codecMode': codecMode,
    'debugLogging': debugLogging,
    'logSymbols': logSymbols,
    'handshakeTimeoutMs': handshakeTimeoutMs,
    'maxHandshakeRetries': maxHandshakeRetries,
  };

  factory NadeConfig.fromJson(Map<String, dynamic> json) => NadeConfig(
    sampleRate: json['sampleRate'] as int? ?? 16000,
    symbolRate: (json['symbolRate'] as num?)?.toDouble() ?? 100.0,
    frequencies: (json['frequencies'] as List?)?.cast<int>() ?? [600, 900, 1200, 1500],
    fecStrength: json['fecStrength'] as int? ?? 32,
    codecMode: json['codecMode'] as int? ?? 1400,
    debugLogging: json['debugLogging'] as bool? ?? false,
    logSymbols: json['logSymbols'] as bool? ?? false,
    handshakeTimeoutMs: json['handshakeTimeoutMs'] as int? ?? 10000,
    maxHandshakeRetries: json['maxHandshakeRetries'] as int? ?? 5,
  );
}

/// NADE event types
enum NadeEventType {
  handshakeStarted,
  handshakeSuccess,
  handshakeFailed,
  sessionEstablished,
  sessionClosed,
  fecCorrection,
  syncLost,
  syncAcquired,
  remoteNotNade,
  log,
  error,
  unknown,
}

/// NADE event object
class NadeEvent {
  final NadeEventType type;
  final String message;
  final Map<String, dynamic>? data;
  final DateTime timestamp;

  NadeEvent({
    required this.type,
    required this.message,
    this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory NadeEvent.fromMap(Map<String, dynamic> map) {
    return NadeEvent(
      type: _parseEventType(map['type'] as String?),
      message: map['message'] as String? ?? '',
      data: map['data'] as Map<String, dynamic>?,
      timestamp: map['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int)
          : DateTime.now(),
    );
  }

  static NadeEventType _parseEventType(String? typeStr) {
    switch (typeStr) {
      case 'handshake_started':
        return NadeEventType.handshakeStarted;
      case 'handshake_success':
        return NadeEventType.handshakeSuccess;
      case 'handshake_failed':
        return NadeEventType.handshakeFailed;
      case 'session_established':
        return NadeEventType.sessionEstablished;
      case 'session_closed':
        return NadeEventType.sessionClosed;
      case 'fec_correction':
        return NadeEventType.fecCorrection;
      case 'sync_lost':
        return NadeEventType.syncLost;
      case 'sync_acquired':
        return NadeEventType.syncAcquired;
      case 'remote_not_nade':
        return NadeEventType.remoteNotNade;
      case 'log':
        return NadeEventType.log;
      case 'error':
        return NadeEventType.error;
      default:
        return NadeEventType.unknown;
    }
  }

  @override
  String toString() {
    return 'NadeEvent{type: $type, message: $message, timestamp: $timestamp}';
  }
}
