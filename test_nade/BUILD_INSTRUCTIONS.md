# NADE Flutter - Build & Test Instructions

## ⚠️ Current Status

**Can you run `flutter run` now?** → **Almost, but NOT YET**

The code is complete but you need to:
1. Build the native library first
2. Install test app dependencies
3. Connect an Android device or emulator

---

## Prerequisites

- ✅ Flutter SDK installed
- ✅ Android SDK (API 21+)
- ✅ NDK (Android Native Development Kit)
- ✅ CMake 3.10+ (usually comes with Android Studio)
- ✅ Android device or emulator
- ✅ Microphone permission (for testing)

---

## Quick Start - Test NADE Plugin

### Step 1: Install Dependencies

```powershell
# Go to test app directory
cd test_nade

# Get Flutter dependencies
flutter pub get
```

### Step 2: Build Native Library

The native library will be built automatically during `flutter run`, but you can pre-build it:

```powershell
# From test_nade directory
flutter build apk --debug
```

This will:
- Invoke CMake to compile C code
- Build libnadecore.so for all Android architectures
- Package it into the Flutter plugin

### Step 3: Connect Device and Run

```powershell
# Check devices
flutter devices

# Run on connected device
flutter run

# Or run on specific device
flutter run -d <device-id>
```

---

## Expected Build Output

### ✅ Success Looks Like:

```
Building with sound null safety
Launching lib\main.dart on Android SDK built for x86_64 in debug mode...
Running Gradle task 'assembleDebug'...
CMake: Looking for libnadecore at: C:/Users/.../native/libnadecore
CMake: -- Configuring done
CMake: -- Generating done
CMake: Build files have been written to...
> Task :nade_flutter:buildCMakeDebug[arm64-v8a]
[1/7] Building C object ...
[7/7] Linking C shared library libnadecore.so
✓ Built build\app\outputs\flutter-apk\app-debug.apk
Installing...
```

### ❌ Common Errors & Fixes

#### Error 1: CMake not found
```
FAILURE: Build failed with an exception.
* What went wrong:
CMake executable is not found
```

**Fix:** Install CMake via Android Studio SDK Manager

#### Error 2: NDK not found
```
No version of NDK matched the requested version
```

**Fix:**
```powershell
# In Android Studio: Tools > SDK Manager > SDK Tools > NDK
# Or set in android/local.properties:
sdk.dir=C:\\Users\\<you>\\AppData\\Local\\Android\\Sdk
ndk.dir=C:\\Users\\<you>\\AppData\\Local\\Android\\Sdk\\ndk\\<version>
```

#### Error 3: pthread errors
```
undefined reference to `pthread_mutex_init`
```

**Fix:** Already handled in CMakeLists.txt - rebuild clean:
```powershell
flutter clean
flutter pub get
flutter run
```

#### Error 4: JNI errors
```
java.lang.UnsatisfiedLinkError: dlopen failed: cannot locate symbol
```

**Fix:** This means native library compiled but symbols don't match. Rebuild:
```powershell
cd android
./gradlew clean
cd ..
flutter clean
flutter run
```

---

## Testing on Real Devices

### Loopback Test (Single Device)

The test app will:
1. Initialize NADE
2. Start a session
3. Capture mic audio → encode → encrypt → modulate
4. Demodulate → decrypt → decode → play to speaker

You should hear your own voice (with delay + artifacts from codec/FSK).

### Two-Device Test

**Device 1:**
```dart
await Nade.startCall(peerId: 'device2', transport: 'bluetooth');
```

**Device 2:**
```dart
await Nade.startCall(peerId: 'device1', transport: 'bluetooth');
```

They should establish encrypted voice session over Bluetooth audio.

---

## Debugging

### Enable Verbose Logging

In `test_nade/lib/main.dart`:
```dart
NadeConfig(
  debugLogging: true,  // ← Enable this
  // ...
)
```

### Check Logcat

```powershell
# Filter for NADE logs
adb logcat | findstr "NADE"

# Or Android Studio: Logcat tab, filter "NADE"
```

You should see:
```
[NADE] Event: HANDSHAKE_STARTED - Starting Noise XK handshake
[NADE] Event: HANDSHAKE_SUCCESS - Handshake completed
[NADE] Event: SESSION_ESTABLISHED - Session established
```

### Check Native Crashes

```powershell
adb logcat | findstr "FATAL"
```

---

## Build Verification Steps

### 1. Check Native Library Built

After `flutter run`, verify `.so` file exists:

**Windows:**
```powershell
ls test_nade\.dart_tool\flutter_build\**\libnadecore.so
```

**Expected output:**
```
libnadecore.so (for arm64-v8a)
libnadecore.so (for armeabi-v7a)
libnadecore.so (for x86)
libnadecore.so (for x86_64)
```

### 2. Check Symbols Exported

```powershell
# Install NDK binutils
cd %ANDROID_NDK_HOME%\toolchains\llvm\prebuilt\windows-x86_64\bin

# Check symbols
.\llvm-nm.exe ...\libnadecore.so | findstr "Java_com_icing"
```

Should show:
```
T Java_com_icing_nade_NadePlugin_nativeInit
T Java_com_icing_nade_NadePlugin_nativeStartSession
...
```

### 3. Test JNI Calls

In test app, you should see in logs:
```
NADE initialized successfully
Call started
Event: HANDSHAKE_STARTED
```

If you see "Undefined name 'Nade'" errors, run:
```powershell
cd test_nade
flutter pub get
```

---

## Integration into Main BT-Call App

Once NADE test app works, integrate into your main app:

### 1. Add dependency to main `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  nade_flutter:
    path: ./nade_flutter
  # ... other deps
```

### 2. Replace old Bluetooth audio code

Find where you currently handle Bluetooth audio calls and replace with:

```dart
import 'package:nade_flutter/nade_flutter.dart';

// Start encrypted call
await Nade.startCall(
  peerId: bluetoothDevice.address,
  transport: 'bluetooth'
);

// Stop call
await Nade.stopCall();
```

---

## Performance Expectations

| Metric | Expected Value |
|--------|---------------|
| CPU Usage | 5-15% on modern phones |
| Latency | 100-300ms (4-FSK + crypto overhead) |
| Audio Quality | Fair (Codec2 at 1400bps is ~phone quality) |
| Battery Drain | Similar to regular Bluetooth call |
| Security | End-to-end encrypted (Noise XK + ChaCha20) |

---

## Next Steps After Test Succeeds

1. ✅ Test loopback mode
2. ✅ Test with 2 devices
3. 🔨 Tune FSK parameters for real Bluetooth audio
4. 🔨 Add sync patterns for better demodulation
5. 🔨 Integrate production crypto libraries
6. 🔨 Implement Windows plugin
7. 🔨 Add comprehensive error handling

---

## Troubleshooting Checklist

- [ ] CMake version ≥ 3.10?
- [ ] NDK installed via Android Studio?
- [ ] `flutter doctor` shows no errors?
- [ ] Device connected: `adb devices` shows device?
- [ ] Microphone permission granted?
- [ ] `flutter clean` run recently?
- [ ] Test app dependencies installed: `flutter pub get`?
- [ ] Native library path correct in CMakeLists.txt?
- [ ] Android SDK ≥ 21 (Lollipop)?

---

## Summary

**Current Status:** ✅ Code is ready, ⚠️ Build needs testing

**To test NADE:**
```powershell
cd test_nade
flutter pub get
flutter run
```

**Expected result:** App launches, shows "Initialized" status, you can start/stop calls, see logs of NADE events.

**If build fails:** Check error messages against "Common Errors" section above.

**Next:** Once test app works, integrate into main BT-Call app.
