# NADE Third-Party Dependencies Setup

This guide walks you through setting up the required third-party libraries for NADE.

## Required Libraries

1. **noise-c** - Noise Protocol implementation
2. **codec2** - Low bitrate voice codec
3. **libfec** - Forward Error Correction (Reed-Solomon)

## Setup Steps

### 1. Add as Git Submodules

From the repository root:

```powershell
cd native\libnadecore

# Create third_party directory
mkdir third_party
cd third_party

# Add noise-c
git submodule add https://github.com/rweather/noise-c.git noise-c

# Add codec2
git submodule add https://github.com/drowe67/codec2.git codec2

# Add libfec
git submodule add https://github.com/quiet/libfec.git libfec

# Initialize and update all submodules
git submodule update --init --recursive
```

### 2. Update CMakeLists.txt

Edit `native/libnadecore/CMakeLists.txt` and uncomment the dependency sections:

```cmake
# Add third-party dependencies
add_subdirectory(third_party/noise-c)
add_subdirectory(third_party/codec2)
add_subdirectory(third_party/libfec)

# In target_link_libraries section:
if(ANDROID)
    target_link_libraries(nadecore noise codec2 fec ${log-lib} pthread)
elseif(WIN32)
    target_link_libraries(nadecore noise codec2 fec ws2_32)
else()
    target_link_libraries(nadecore noise codec2 fec pthread)
endif()
```

### 3. Build Dependencies

#### For Android (all ABIs)

The Flutter build system will automatically compile dependencies when you run:

```powershell
cd nade_flutter\example
flutter build apk
```

#### For Windows

```powershell
cd native\libnadecore\build

# Configure
cmake .. -G "Visual Studio 16 2019" -A x64

# Build
cmake --build . --config Release

# The output will be in build\Release\nadecore.dll
```

## Library Integration Details

### noise-c

**Purpose**: Noise Protocol Framework XK pattern  
**Files needed**:
- `protocol/handshakestate.h`
- `protocol/cipherstate.h`
- Link: `libnoise.a` (static) or `noise.lib` (Windows)

**Usage in NADE**:
```c
#include <noise/protocol.h>

// Initialize Noise handshake
NoiseHandshakeState *handshake;
noise_handshakestate_new_by_name(&handshake, "Noise_XK_25519_ChaChaPoly_SHA256", ...);
```

### codec2

**Purpose**: Voice compression (1.4-3.2 kbps)  
**Files needed**:
- `codec2.h`
- Link: `libcodec2.a` or `codec2.lib`

**Usage in NADE**:
```c
#include <codec2/codec2.h>

// Create codec instance
struct CODEC2 *codec = codec2_create(CODEC2_MODE_1400);

// Encode speech
codec2_encode(codec, encoded_bits, pcm_samples);

// Decode
codec2_decode(codec, pcm_out, encoded_bits);
```

### libfec

**Purpose**: Reed-Solomon FEC for error resilience  
**Files needed**:
- `fec.h`
- Link: `libfec.a` or `fec.lib`

**Usage in NADE**:
```c
#include <fec.h>

// Create RS(255, 223) encoder
void *rs = init_rs_char(8, 0x11d, 0, 1, 32);

// Encode: add 32 parity bytes
encode_rs_char(rs, data, parity);

// Decode: correct up to 16 errors
int errors_corrected = decode_rs_char(rs, data, NULL, 0);
```

## Alternative: Pre-built Binaries

If building from source is problematic, you can download pre-built binaries:

### Windows

1. Download from project releases or build server
2. Place in `nade_flutter\windows\`:
   - `nadecore.dll`
   - `noise.dll`
   - `codec2.dll`
   - `fec.dll`

### Android

1. Download AAR package or prebuilt `.so` files
2. Place in `nade_flutter\android\src\main\jniLibs\{abi}\`:
   - `libnadecore.so`
   - `libnoise.so`
   - `libcodec2.so`
   - `libfec.so`

## Verification

After setup, verify the build:

```powershell
# Android
cd nade_flutter\example
flutter build apk --debug
flutter install

# Windows
cd native\libnadecore\build
ctest  # Run native tests

# Check symbols are exported
dumpbin /EXPORTS Release\nadecore.dll  # Windows
nm -D libnadecore.so  # Linux/Android
```

Expected exported symbols:
- `nade_init`
- `nade_start_session`
- `nade_feed_mic_frame`
- `nade_pull_speaker_frame`
- `fsk_modulate`
- `fsk_demodulate`

## Troubleshooting

### "Cannot find noise.h"

Ensure submodules are initialized:
```powershell
git submodule update --init --recursive
```

### "Undefined reference to codec2_create"

Check that codec2 is being linked:
```cmake
target_link_libraries(nadecore codec2)
```

### "CMake Error: Could not find a package configuration file"

Some libraries may not have CMake support. Add custom `CMakeLists.txt`:

```cmake
# third_party/libfec/CMakeLists.txt
add_library(fec STATIC
    fec.c
    rs.c
)
target_include_directories(fec PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
```

## Next Steps

Once dependencies are set up:

1. Implement `handshake.c` using noise-c API
2. Implement `codec.c` using codec2 API  
3. Implement `fec.c` using libfec API
4. Wire into main pipeline in `nade_core.c`
5. Test end-to-end encryption

See `README.md` for full integration guide.
