# Integrating NADE into BT-Call App

This guide shows how to replace your current Bluetooth audio pipeline with NADE encrypted calls.

## Overview

Your current architecture:
```
BluetoothProvider → BluetoothAudioService → FourFskService → Bluetooth
```

New NADE architecture:
```
BluetoothProvider → Nade Plugin → libnadecore (Codec2 + FEC + Crypto + FSK) → Bluetooth
```

## Step-by-Step Integration

### 1. Add NADE as Dependency

Update `pubspec.yaml`:

```yaml
dependencies:
  nade_flutter:
    path: ./nade_flutter
```

Run:
```powershell
flutter pub get
```

### 2. Initialize NADE in main.dart

Replace current initialization:

```dart
// OLD:
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  BluetoothAudioService.initialize(
    FourFskService(
      sampleRate: 8000,
      symbolRate: 100.0,
      frequencies: [1200, 1600, 2000, 2400],
    ),
  );
  runApp(const MyApp());
}

// NEW:
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize NADE with secure keypair
  final keyPair = await _loadOrGenerateKeyPair();
  await Nade.initialize(
    identityKeyPairPem: keyPair,
    config: const NadeConfig(
      sampleRate: 16000,  // Changed from 8000 for better quality
      symbolRate: 100.0,
      frequencies: [600, 900, 1200, 1500],  // Phone band frequencies
      codecMode: 1400,  // Codec2 1400 bps mode
      debugLogging: true,
    ),
  );
  
  runApp(const MyApp());
}

Future<String> _loadOrGenerateKeyPair() async {
  final storage = FlutterSecureStorage();
  
  // Try to load existing keypair
  String? keyPair = await storage.read(key: 'nade_identity_keypair');
  
  if (keyPair == null) {
    // Generate new keypair (use proper crypto library in production)
    // For now, placeholder - TODO: integrate with libsodium or similar
    keyPair = await _generateEd25519KeyPair();
    await storage.write(key: 'nade_identity_keypair', value: keyPair);
  }
  
  return keyPair;
}
```

### 3. Create NadeProvider

Create `lib/src/providers/nade_provider.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:nade_flutter/nade_flutter.dart';

class NadeProvider extends ChangeNotifier {
  bool _inSecureCall = false;
  String? _currentPeerId;
  String _lastEvent = '';
  bool _handshakeComplete = false;
  
  bool get inSecureCall => _inSecureCall;
  String? get currentPeerId => _currentPeerId;
  String get lastEvent => _lastEvent;
  bool get handshakeComplete => _handshakeComplete;

  NadeProvider() {
    // Set up event handler
    Nade.setEventHandler(_handleEvent);
  }

  void _handleEvent(NadeEvent event) {
    _lastEvent = '${event.type.name}: ${event.message}';
    
    switch (event.type) {
      case NadeEventType.handshakeSuccess:
        _handshakeComplete = true;
        break;
      case NadeEventType.sessionEstablished:
        _inSecureCall = true;
        break;
      case NadeEventType.sessionClosed:
        _inSecureCall = false;
        _handshakeComplete = false;
        _currentPeerId = null;
        break;
      case NadeEventType.error:
      case NadeEventType.handshakeFailed:
        _inSecureCall = false;
        _handshakeComplete = false;
        break;
      default:
        break;
    }
    
    notifyListeners();
  }

  Future<bool> startSecureCall(String peerId) async {
    _currentPeerId = peerId;
    
    final success = await Nade.startCall(
      peerId: peerId,
      transport: 'bluetooth',
    );
    
    if (!success) {
      _currentPeerId = null;
    }
    
    notifyListeners();
    return success;
  }

  Future<void> endSecureCall() async {
    await Nade.stopCall();
    _currentPeerId = null;
    _inSecureCall = false;
    _handshakeComplete = false;
    notifyListeners();
  }

  Future<bool> checkPeerCompatibility(String peerId) async {
    return await Nade.isPeerNadeCapable(peerId);
  }

  @override
  void dispose() {
    Nade.removeEventHandler();
    super.dispose();
  }
}
```

### 4. Update BluetoothProvider

Modify `lib/src/providers/bluetooth_provider.dart`:

```dart
import 'package:nade_flutter/nade_flutter.dart';

class BluetoothProvider extends ChangeNotifier {
  // ... existing code ...
  
  NadeProvider? _nadeProvider;
  
  void attachNadeProvider(NadeProvider nadeProvider) {
    _nadeProvider = nadeProvider;
  }

  // Replace startCall method
  Future<void> startCall(String macAddress, Contact contact) async {
    // OLD: Used bluetooth_audio_service
    // await _audioService.connectToDevice(macAddress, ...);
    
    // NEW: Use NADE for secure calls
    if (_nadeProvider != null) {
      final success = await _nadeProvider!.startSecureCall(contact.phoneNumber);
      
      if (success) {
        _currentCall = CallSession(
          contact: contact,
          startTime: DateTime.now(),
          isSecure: true,  // Add this flag
        );
        notifyListeners();
      }
    }
  }

  Future<void> endCall() async {
    if (_nadeProvider != null && _nadeProvider!.inSecureCall) {
      await _nadeProvider!.endSecureCall();
    }
    
    _currentCall = null;
    notifyListeners();
  }
}
```

### 5. Update main.dart Providers

```dart
class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ContactsProvider()),
        ChangeNotifierProvider(create: (_) => NadeProvider()),  // NEW
        ChangeNotifierProxyProvider2<ContactsProvider, NadeProvider, BluetoothProvider>(
          create: (_) => BluetoothProvider(),
          update: (_, contactsProvider, nadeProvider, bluetoothProvider) {
            final provider = bluetoothProvider ?? BluetoothProvider();
            provider.attachContactsProvider(contactsProvider);
            provider.attachNadeProvider(nadeProvider);  // NEW
            return provider;
          },
        ),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, child) {
          return MaterialApp(
            title: 'BTCalls - Secure',
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            home: const HomeScreen(),
          );
        },
      ),
    );
  }
}
```

### 6. Update UI to Show Security Status

Modify your call screen to display NADE status:

```dart
// In your call screen widget
Consumer<NadeProvider>(
  builder: (context, nadeProvider, child) {
    return Column(
      children: [
        // Security indicator
        Container(
          padding: EdgeInsets.all(8),
          color: nadeProvider.handshakeComplete 
              ? Colors.green.withOpacity(0.2) 
              : Colors.orange.withOpacity(0.2),
          child: Row(
            children: [
              Icon(
                nadeProvider.handshakeComplete 
                    ? Icons.lock 
                    : Icons.lock_open,
                color: nadeProvider.handshakeComplete 
                    ? Colors.green 
                    : Colors.orange,
              ),
              SizedBox(width: 8),
              Text(
                nadeProvider.handshakeComplete
                    ? 'End-to-End Encrypted'
                    : 'Establishing Secure Connection...',
                style: TextStyle(
                  color: nadeProvider.handshakeComplete 
                      ? Colors.green 
                      : Colors.orange,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        
        // Last event
        if (nadeProvider.lastEvent.isNotEmpty)
          Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              nadeProvider.lastEvent,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        
        // ... rest of your call UI ...
      ],
    );
  },
)
```

### 7. Update CallSession Model

Add security indicator to your call session:

```dart
class CallSession {
  final Contact contact;
  final DateTime startTime;
  final bool isSecure;  // NEW
  final String? encryptionFingerprint;  // NEW - for key verification

  CallSession({
    required this.contact,
    required this.startTime,
    this.isSecure = false,
    this.encryptionFingerprint,
  });
}
```

### 8. Add Key Verification UI

Create a screen to verify encryption keys (QR code based):

```dart
// lib/src/screens/key_verification_screen.dart
import 'package:qr_flutter/qr_flutter.dart';

class KeyVerificationScreen extends StatelessWidget {
  final String localFingerprint;
  final String? remoteFingerprint;

  const KeyVerificationScreen({
    required this.localFingerprint,
    this.remoteFingerprint,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Verify Encryption Key')),
      body: Column(
        children: [
          // Show local key as QR code
          QrImageView(
            data: localFingerprint,
            size: 200,
          ),
          
          Text('Your Key Fingerprint'),
          SelectableText(
            localFingerprint,
            style: TextStyle(fontFamily: 'Courier'),
          ),
          
          Divider(),
          
          // Compare with remote
          if (remoteFingerprint != null) ...[
            Text('Remote Key Fingerprint'),
            SelectableText(
              remoteFingerprint!,
              style: TextStyle(fontFamily: 'Courier'),
            ),
            
            ElevatedButton.icon(
              icon: Icon(Icons.verified_user),
              label: Text('Mark as Trusted'),
              onPressed: () {
                // TODO: Store trusted key
              },
            ),
          ],
          
          // Scan remote QR
          ElevatedButton.icon(
            icon: Icon(Icons.qr_code_scanner),
            label: Text('Scan Partner\'s Code'),
            onPressed: () {
              // TODO: Launch QR scanner
            },
          ),
        ],
      ),
    );
  }
}
```

## Migration Checklist

- [ ] Build NADE native libraries (libnadecore.so for Android)
- [ ] Update pubspec.yaml with NADE dependency
- [ ] Generate/load identity keypair securely
- [ ] Initialize NADE in main.dart
- [ ] Create NadeProvider
- [ ] Update BluetoothProvider to use NADE
- [ ] Update providers in MyApp
- [ ] Add security indicators to call UI
- [ ] Test local call (loopback)
- [ ] Test Android ↔ Android call
- [ ] Implement key verification UI
- [ ] Add trusted contacts storage
- [ ] Performance testing and optimization

## Testing Strategy

### Phase 1: Local Testing
```dart
// Test with audio loopback transport
await Nade.startCall(
  peerId: 'loopback',
  transport: 'audio_loopback',
);
```

### Phase 2: Device Testing
1. Build on two Android devices
2. Pair via Bluetooth
3. Start NADE call
4. Monitor logs for handshake events
5. Verify voice quality

### Phase 3: Cross-Platform
1. Test Windows ↔ Android (once Windows plugin is complete)
2. Verify encryption compatibility
3. Measure latency and throughput

## Fallback Mode

Maintain compatibility with non-NADE peers:

```dart
Future<void> startCallWithFallback(String macAddress, Contact contact) async {
  // Try NADE first
  bool nadeCapable = await _nadeProvider!.checkPeerCompatibility(contact.phoneNumber);
  
  if (nadeCapable) {
    // Use NADE
    await _nadeProvider!.startSecureCall(contact.phoneNumber);
  } else {
    // Fall back to original FourFSK without encryption
    await _audioService.connectToDevice(macAddress, decrypt: false, encrypt: false);
  }
}
```

## Troubleshooting

### "Handshake times out"
- Check Bluetooth audio routing
- Verify both devices use same NADE version
- Enable debug logging and check symbol detection

### "No audio"
- Ensure AudioRecord/AudioTrack permissions
- Check sample rate compatibility (16kHz)
- Verify Bluetooth SCO mode (not A2DP)

### "Build fails on Android"
- Ensure NDK r21+ installed
- Check CMake path in build.gradle
- Verify third-party libs are present

## Next Steps

After basic integration:
1. Implement proper key generation (Ed25519)
2. Add contact key management (trusted keys DB)
3. Implement SAS verification (Short Authentication String)
4. Add call quality indicators (FEC stats, signal strength)
5. Performance profiling and optimization

## Security Considerations

⚠️ **Important**: Current implementation uses placeholder crypto. For production:

1. **Key Generation**: Use libsodium or platform crypto APIs
2. **Key Storage**: Android Keystore / iOS Keychain / Windows DPAPI
3. **Trust**: Implement TOFU (Trust On First Use) + verification
4. **Forward Secrecy**: Rotate session keys periodically
5. **Audit**: Security review of crypto implementation

See `nade_flutter/README.md` for detailed security architecture.
