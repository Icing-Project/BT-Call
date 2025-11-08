# NADE Test App - Quick Build Script

Write-Host "NADE Flutter Test App Build Script" -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""

# Check if flutter is installed
Write-Host "Checking Flutter installation..." -ForegroundColor Yellow
$flutterCheck = flutter --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Flutter not found! Please install Flutter first." -ForegroundColor Red
    exit 1
}
Write-Host "Flutter found" -ForegroundColor Green
Write-Host ""

# Check for connected devices
Write-Host "Checking for connected devices..." -ForegroundColor Yellow
$devices = flutter devices 2>&1
Write-Host $devices
if ($devices -match "No devices detected") {
    Write-Host "No devices connected. Please connect an Android device or start an emulator." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To start an emulator:" -ForegroundColor Cyan
    Write-Host "  1. Open Android Studio" -ForegroundColor Cyan
    Write-Host "  2. Tools > Device Manager" -ForegroundColor Cyan
    Write-Host "  3. Create/Start a device" -ForegroundColor Cyan
    Write-Host ""
    $continue = Read-Host "Continue anyway? (y/n)"
    if ($continue -ne "y") {
        exit 1
    }
}
Write-Host ""

# Clean previous builds
Write-Host "Cleaning previous builds..." -ForegroundColor Yellow
flutter clean
if ($LASTEXITCODE -ne 0) {
    Write-Host "Flutter clean failed" -ForegroundColor Red
    exit 1
}
Write-Host "Clean complete" -ForegroundColor Green
Write-Host ""

# Get dependencies
Write-Host "Getting Flutter dependencies..." -ForegroundColor Yellow
flutter pub get
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to get dependencies" -ForegroundColor Red
    exit 1
}
Write-Host "Dependencies installed" -ForegroundColor Green
Write-Host ""

# Build and run
Write-Host "Building and running app..." -ForegroundColor Yellow
Write-Host "This will:" -ForegroundColor Cyan
Write-Host "  1. Compile native C code (libnadecore)" -ForegroundColor Cyan
Write-Host "  2. Build Android APK" -ForegroundColor Cyan
Write-Host "  3. Install on device" -ForegroundColor Cyan
Write-Host "  4. Launch the app" -ForegroundColor Cyan
Write-Host ""
Write-Host "This may take 2-5 minutes on first build..." -ForegroundColor Yellow
Write-Host ""

flutter run --verbose

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Build successful!" -ForegroundColor Green
    Write-Host ""
    Write-Host "App should now be running on your device" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Grant microphone permission when prompted" -ForegroundColor White
    Write-Host "  2. Tap Start Call to test NADE" -ForegroundColor White
    Write-Host "  3. Check logs for events" -ForegroundColor White
    Write-Host "  4. You should hear your voice (loopback mode)" -ForegroundColor White
} else {
    Write-Host ""
    Write-Host "Build failed!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Common issues:" -ForegroundColor Yellow
    Write-Host "  - CMake not found: Install via Android Studio SDK Manager" -ForegroundColor White
    Write-Host "  - NDK not found: Install via Android Studio SDK Manager" -ForegroundColor White
    Write-Host "  - Device not found: Connect device or start emulator" -ForegroundColor White
    Write-Host ""
    Write-Host "For more help, see BUILD_INSTRUCTIONS.md" -ForegroundColor Cyan
}
