# NADE Quick Start Guide

Get NADE up and running in 10 minutes (after dependencies are set up).

## Prerequisites

- Flutter 3.0+
- Android Studio with NDK r21+
- Git

## Step 1: Clone and Setup Dependencies (5 min)

```powershell
# Navigate to your BT-Call repository
cd c:\Users\adanl\Documents\GitHub\BT-Call

# Add third-party dependencies
cd native\libnadecore
mkdir third_party
cd third_party

# Add submodules
git submodule add https://github.com/rweather/noise-c.git
git submodule add https://github.com/drowe67/codec2.git
git submodule add https://github.com/quiet/libfec.git

# Initialize
git submodule update --init --recursive
```

## Step 2: Update CMakeLists.txt (2 min)

Edit `native\libnadecore\CMakeLists.txt` and uncomment these lines:

```cmake
# Around line 30, uncomment:
add_subdirectory(third_party/noise-c)
add_subdirectory(third_party/codec2)
add_subdirectory(third_party/libfec)

# Around line 50, uncomment:
target_link_libraries(nadecore noise codec2 fec ${log-lib} pthread)
```

## Step 3: Build Native Library (2 min)

```powershell
# For Android (if you have android-ndk)
cd ..\..\nade_flutter\example
flutter build apk --debug

# This will compile libnadecore.so via CMake/NDK
```

## Step 4: Run Example App (1 min)

```powershell
# Connect Android device via USB
flutter devices

# Install and run
flutter run
```

## What You'll See

The example app will show:

1. ✅ **Initialize Button** - Tap to initialize NADE core
2. 📱 **Peer ID Field** - Enter a test peer ID
3. 📞 **Start Call Button** - Begin encrypted call
4. 📊 **Event Log** - Real-time NADE events
5. 🔒 **Security Status** - Handshake progress

## Test Locally (Loopback)

```dart
// In the app, set transport to loopback for testing
await Nade.startCall(
  peerId: 'test',
  transport: 'audio_loopback',
);
```

This routes modulated audio directly back to the demodulator without Bluetooth.

## Test Between Two Devices

1. Build app on Device A and Device B
2. Pair devices via Bluetooth
3. On Device A: Enter Device B's ID, tap "Start Call"
4. On Device B: Should see incoming handshake event
5. Watch event logs for "Handshake Success" and "Session Established"

## Expected Events

```
[12:34:56] ✅ NADE initialized successfully
[12:34:58] 📞 Call started with TestPeer123
[12:34:59] 🤝 handshake_started: Starting Noise XK handshake
[12:35:01] ✅ handshake_success: Handshake completed
[12:35:01] 🔒 session_established: Session established
[12:35:05] 📡 fec_correction: Corrected 2 errors in frame 42
```

## Troubleshooting Quick Fixes

### "Build failed: Cannot find noise.h"
```powershell
# Ensure submodules initialized
git submodule update --init --recursive
```

### "No events appearing"
```dart
// Make sure you called initialize first
await Nade.initialize(...);
Nade.setEventHandler((event) => print(event));
```

### "Call starts but no handshake"
- Check Bluetooth is connected and audio routing is active
- Enable debug logging: `NadeConfig(debugLogging: true)`
- Check logcat: `adb logcat | grep NADE`

### "Audio quality poor"
```dart
// Try lower symbol rate
NadeConfig(symbolRate: 60.0)

// Or higher FEC
NadeConfig(fecStrength: 48)
```

## Next Steps

After basic testing works:

1. **Integrate with BT-Call**: Follow `NADE_INTEGRATION.md`
2. **Add Crypto**: Implement handshake.c using noise-c API
3. **Test Real Calls**: Two devices over Bluetooth
4. **Optimize**: Profile and tune parameters

## Getting Help

- **Documentation**: See `nade_flutter/README.md`
- **Integration Guide**: See `NADE_INTEGRATION.md`
- **Project Status**: See `PROJECT_SUMMARY.md`
- **Issues**: https://github.com/Icing-Project/BT-Call/issues

## Success Criteria

You know it's working when:
- ✅ App initializes without errors
- ✅ Start Call returns `true`
- ✅ Event log shows "handshake_started"
- ✅ Event log shows "session_established"
- ✅ No crash when ending call

## Current Limitations (Alpha v0.1.0)

⚠️ **Note**: This is a foundation/prototype. Crypto is not yet integrated.

- ❌ Actual encryption not implemented (placeholders only)
- ❌ Voice not yet compressed with Codec2
- ❌ FEC not yet applied
- ❌ Handshake is simulated, not real Noise protocol
- ✅ FSK modulation/demodulation works
- ✅ Audio pipeline structure complete
- ✅ Session management functional

**For production use, complete tasks in `PROJECT_SUMMARY.md`**

---

**Estimated time to first run**: 10 minutes  
**Estimated time to functional crypto**: 2 weeks development
