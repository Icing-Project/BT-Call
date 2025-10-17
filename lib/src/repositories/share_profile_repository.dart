import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class ShareProfileRepository {
  ShareProfileRepository({SharedPreferences? preferences})
      : _prefsFuture = preferences != null
            ? Future.value(preferences)
            : SharedPreferences.getInstance();

  static const _displayNameKey = 'share_profile_display_name';
  static const _keyAliasKey = 'share_profile_key_alias';
  static const _discoveryHintKey = 'share_profile_discovery_hint';

  final Future<SharedPreferences> _prefsFuture;

  Future<String?> loadDisplayName() async {
    final prefs = await _prefsFuture;
    return prefs.getString(_displayNameKey);
  }

  Future<void> saveDisplayName(String value) async {
    final prefs = await _prefsFuture;
    await prefs.setString(_displayNameKey, value);
  }

  Future<String?> loadKeyAlias() async {
    final prefs = await _prefsFuture;
    return prefs.getString(_keyAliasKey);
  }

  Future<void> saveKeyAlias(String alias) async {
    final prefs = await _prefsFuture;
    await prefs.setString(_keyAliasKey, alias);
  }

  Future<String?> loadDiscoveryHint() async {
    final prefs = await _prefsFuture;
    final value = prefs.getString(_discoveryHintKey);
    return value?.toUpperCase();
  }

  Future<void> saveDiscoveryHint(String value) async {
    final prefs = await _prefsFuture;
    await prefs.setString(_discoveryHintKey, value);
  }

  Future<String> ensureDiscoveryHint() async {
    final prefs = await _prefsFuture;
    final existing = prefs.getString(_discoveryHintKey);
    if (existing != null && existing.isNotEmpty) {
      final normalized = existing.toUpperCase();
      if (normalized != existing) {
        await prefs.setString(_discoveryHintKey, normalized);
      }
      return normalized;
    }
    final generated = _generateDiscoveryHint();
    await prefs.setString(_discoveryHintKey, generated);
    return generated;
  }

  Future<String> regenerateDiscoveryHint() async {
    final prefs = await _prefsFuture;
    final generated = _generateDiscoveryHint();
    await prefs.setString(_discoveryHintKey, generated);
    return generated;
  }

  String _generateDiscoveryHint() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(6, (_) => chars[random.nextInt(chars.length)]).join();
  }
}
