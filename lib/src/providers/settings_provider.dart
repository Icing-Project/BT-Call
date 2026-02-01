import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Provider for app-wide settings like verbose mode for call operations
class SettingsProvider extends ChangeNotifier {
  static const String _verboseKey = 'settings_verbose_mode';
  
  bool _verboseMode = false;
  
  /// Whether verbose mode is enabled - shows detailed call operation info
  bool get verboseMode => _verboseMode;
  
  SettingsProvider() {
    _loadSettings();
  }
  
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _verboseMode = prefs.getBool(_verboseKey) ?? false;
    notifyListeners();
  }
  
  /// Toggle verbose mode on/off
  Future<void> setVerboseMode(bool enabled) async {
    if (_verboseMode == enabled) return;
    _verboseMode = enabled;
    notifyListeners();
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_verboseKey, enabled);
  }
  
  /// Toggle verbose mode
  Future<void> toggleVerboseMode() async {
    await setVerboseMode(!_verboseMode);
  }
}
