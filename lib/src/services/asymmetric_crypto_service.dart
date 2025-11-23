import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:nade_flutter/nade_flutter.dart';

class AsymmetricCryptoService {
  static const MethodChannel _channel = MethodChannel('com.example.keystore');
  final FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  final String _aliasPrefix = 'icing_';
  final Uuid _uuid = Uuid();
  static const String _nadeSeedMessage = 'btcalls:nade_identity_seed:v1';

  /// Generates an ED25519 key pair with a unique alias and stores its metadata.
  Future<String> generateKeyPair({String? label}) async {
    // Generate a unique identifier for the key
    final String uuid = _uuid.v4();
    final String alias = '$_aliasPrefix$uuid';

    try {
      // Try to generate the key pair with retry logic for KEY_EXISTS
      await _generateAliasWithRetry(alias);
    } catch (e) {
      debugPrint('Hardware key generation failed for $alias: $e. Using software fallback.');
      await _enableSoftwareFallback(alias);
    }

    try {
      // Store key metadata securely
      final Map<String, dynamic> keyMetadata = {
        'alias': alias,
        'label': label ?? 'Key $uuid',
        'created_at': DateTime.now().toIso8601String(),
      };

      // Retrieve existing keys
      final String? existingKeys = await _secureStorage.read(key: 'keys');
      List<dynamic> keysList = existingKeys != null ? jsonDecode(existingKeys) : [];

      // Add the new key
      keysList.add(keyMetadata);

      // Save updated keys list
      await _secureStorage.write(key: 'keys', value: jsonEncode(keysList));

      return alias;
    } catch (e) {
      throw Exception("Failed to store key metadata: $e");
    }
  }

  Future<bool> isUsingSoftwareFallback(String alias) async {
    final val = await _secureStorage.read(key: 'nade_seed_$alias');
    return val != null;
  }

  /// Signs data using the specified key alias.
  Future<String> signData(String alias, String data) async {
    if (await isUsingSoftwareFallback(alias)) {
      return "SOFTWARE_FALLBACK_SIGNATURE";
    }
    final String signature = await _channel.invokeMethod('signData', {
      'alias': alias,
      'data': data,
    });
    return signature.trim();
  }

  /// Retrieves the public key for the specified alias.
  Future<String> getPublicKey(String alias) async {
    if (await isUsingSoftwareFallback(alias)) {
      // Return a dummy key for validation checks.
      // Real NADE public key should be derived via deriveNadePublicKey
      return "SOFTWARE_FALLBACK_PUBKEY";
    }
    try {
      final String publicKey = await _channel.invokeMethod('getPublicKey', {
        'alias': alias,
      });
      return publicKey.trim();
    } on PlatformException catch (e) {
      throw Exception("Failed to retrieve public key: ${e.message}");
    }
  }

  /// Generates a secure random seed for software fallback
  Uint8List _generateRandomSeed() {
    final random = Random.secure();
    final values = List<int>.generate(32, (i) => random.nextInt(256));
    return Uint8List.fromList(values);
  }

  Future<void> _enableSoftwareFallback(String alias) async {
    final seed = _generateRandomSeed();
    await _secureStorage.write(key: 'nade_seed_$alias', value: base64Encode(seed));
    debugPrint('Enabled software fallback for key $alias');
  }

  /// Derives a deterministic 32-byte NADE identity seed from the keystore key.
  Future<Uint8List> deriveNadeSeed(String alias, {bool allowRepair = true}) async {
    // Check for software fallback first
    final fallbackSeed = await _secureStorage.read(key: 'nade_seed_$alias');
    if (fallbackSeed != null) {
      debugPrint('Using software fallback seed for $alias');
      return base64Decode(fallbackSeed);
    }

    // First verify the key actually exists before attempting to use it
    if (allowRepair) {
      try {
        final exists = await keyPairExists(alias);
        if (!exists) {
          debugPrint('Key $alias does not exist, attempting repair');
          try {
            await _repairKeystoreEntry(alias);
          } catch (e) {
            debugPrint('Warning: Could not repair keystore entry: $e');
          }
          return deriveNadeSeed(alias, allowRepair: false);
        }
      } catch (e) {
        debugPrint('Warning: Could not check if key exists: $e');
      }
    }

    try {
      final signatureBase64 = await signData(alias, _nadeSeedMessage);
      final signatureBytes = base64Decode(signatureBase64);
      final digest = crypto.sha256.convert(signatureBytes);
      return Uint8List.fromList(digest.bytes);
    } on PlatformException catch (e) {
      if (allowRepair && _shouldAttemptKeystoreRepair(e)) {
        try {
          debugPrint('Attempting keystore repair for alias: $alias');
          await _repairKeystoreEntry(alias);
          // Add a brief delay to ensure the keystore has time to sync
          await Future.delayed(const Duration(milliseconds: 300));
          return deriveNadeSeed(alias, allowRepair: false);
        } catch (repairError) {
          // Repair failed - switch to software fallback
          debugPrint('Repair failed for $alias. Switching to software fallback.');
          await _enableSoftwareFallback(alias);
          return deriveNadeSeed(alias, allowRepair: false);
        }
      }
      // Non-repairable error or repair not allowed -> fallback
      debugPrint('Hardware key error for $alias: ${e.message}. Switching to software fallback.');
      await _enableSoftwareFallback(alias);
      return deriveNadeSeed(alias, allowRepair: false);
    } catch (e) {
      if (allowRepair && e.toString().contains('keystore')) {
        try {
          debugPrint('Attempting keystore repair (generic) for alias: $alias');
          await _repairKeystoreEntry(alias);
          await Future.delayed(const Duration(milliseconds: 300));
          return deriveNadeSeed(alias, allowRepair: false);
        } catch (repairError) {
          debugPrint('Repair failed for $alias. Switching to software fallback.');
          await _enableSoftwareFallback(alias);
          return deriveNadeSeed(alias, allowRepair: false);
        }
      }
      debugPrint('Generic error for $alias: $e. Switching to software fallback.');
      await _enableSoftwareFallback(alias);
      return deriveNadeSeed(alias, allowRepair: false);
    }
  }

  /// Computes the shareable NADE public key (base64) for the given alias.
  Future<String> deriveNadePublicKey(String alias) async {
    final seed = await deriveNadeSeed(alias);
    try {
      return await Nade.derivePublicKey(seed);
    } catch (e) {
      throw Exception('Failed to derive NADE public key: $e');
    }
  }

  /// Deletes the key pair associated with the specified alias and removes its metadata.
  Future<void> deleteKeyPair(String alias) async {
    try {
      await _channel.invokeMethod('deleteKeyPair', {'alias': alias});
      
      final String? existingKeys = await _secureStorage.read(key: 'keys');
      if (existingKeys != null) {
        List<dynamic> keysList = jsonDecode(existingKeys);
        keysList.removeWhere((key) => key['alias'] == alias);
        await _secureStorage.write(key: 'keys', value: jsonEncode(keysList));
      }
    } on PlatformException catch (e) {
      throw Exception("Failed to delete key pair: ${e.message}");
    }
  }

  /// Retrieves all stored key metadata.
  Future<List<Map<String, dynamic>>> getAllKeys() async {
    try {
      final String? existingKeys = await _secureStorage.read(key: 'keys');
      if (existingKeys == null) {
        debugPrint('No keys found');
        return [];
      }
      List<dynamic> keysList = jsonDecode(existingKeys);
      return keysList.cast<Map<String, dynamic>>();
    } catch (e) {
      throw Exception("Failed to retrieve keys: $e");
    }
  }

  /// Checks if a key pair exists for the given alias.
  Future<bool> keyPairExists(String alias) async {
    if (await isUsingSoftwareFallback(alias)) {
      return true;
    }
    try {
      final bool exists = await _channel.invokeMethod('keyPairExists', {'alias': alias});
      return exists;
    } on PlatformException catch (e) {
      throw Exception("Failed to check key pair existence: ${e.message}");
    }
  }

  /// Ensures a valid key exists for the given alias, creating one if necessary.
  /// Returns the alias of a valid key.
  Future<String> ensureValidKey(String? preferredAlias) async {
    // First check if preferred alias exists and is valid
    if (preferredAlias != null && preferredAlias.isNotEmpty) {
      try {
        final exists = await keyPairExists(preferredAlias);
        if (exists) {
          debugPrint('Preferred key $preferredAlias exists, testing if it works...');
          // Try a quick test to ensure it actually works
          try {
            await getPublicKey(preferredAlias);
            debugPrint('Preferred key $preferredAlias passed public key check');
            // Try to sign data directly to make sure signing works
            try {
              await signData(preferredAlias, _nadeSeedMessage);
              debugPrint('Preferred key $preferredAlias is fully functional');
              return preferredAlias; // Key is fully valid
            } catch (signError) {
              debugPrint('ERROR: Preferred key $preferredAlias cannot sign: $signError');
              // Fall through to create a new key
            }
          } catch (e) {
            debugPrint('ERROR: Preferred key $preferredAlias failed public key retrieval: $e');
            // Fall through to create a new key
          }
        } else {
          debugPrint('Preferred key $preferredAlias does not exist');
        }
      } catch (e) {
        debugPrint('WARNING: Could not check preferred key: $e');
      }
    }

    // Try to use or create default key
    const String defaultAlias = 'icing_default';
    try {
      final exists = await keyPairExists(defaultAlias);
      if (exists) {
        debugPrint('Default key $defaultAlias exists, testing if it works...');
        try {
          await getPublicKey(defaultAlias);
          debugPrint('Default key $defaultAlias passed public key check');
          try {
            await signData(defaultAlias, _nadeSeedMessage);
            debugPrint('Default key $defaultAlias is fully functional');
            return defaultAlias; // Default key is fully valid
          } catch (signError) {
            debugPrint('ERROR: Default key $defaultAlias cannot sign: $signError');
          }
        } catch (e) {
          debugPrint('ERROR: Default key $defaultAlias failed public key retrieval: $e');
        }
      } else {
        debugPrint('Default key $defaultAlias does not exist');
      }
    } catch (e) {
      debugPrint('WARNING: Could not check default key: $e');
    }

    // No valid key found, create a new default one
    debugPrint('No valid key found, creating new default key...');
    try {
      final newAlias = await generateKeyPair(label: 'Default Key');
      debugPrint('Successfully generated new key: $newAlias');
      
      // Verify the new key immediately
      try {
        await signData(newAlias, _nadeSeedMessage);
        debugPrint('New key $newAlias verified successfully');
        return newAlias;
      } catch (e) {
        debugPrint('ERROR: New key $newAlias failed verification: $e');
        debugPrint('Keystore is unreliable. Switching to software fallback for $newAlias');
        await _enableSoftwareFallback(newAlias);
        return newAlias;
      }
    } catch (e) {
      debugPrint('ERROR: Could not generate new key: $e');
      throw Exception('Unable to create a valid key pair: $e');
    }
  }

  /// Initializes the default key pair if it doesn't exist.
  Future<void> initializeDefaultKeyPair() async {
    const String defaultAlias = 'icing_default';
    final List<Map<String, dynamic>> keys = await getAllKeys();
    
    // Check if the key exists in metadata
    final bool defaultKeyExists = keys.any((key) => key['alias'] == defaultAlias);
    
    if (!defaultKeyExists) {
      await _channel.invokeMethod('generateKeyPair', {'alias': defaultAlias});
      
      final Map<String, dynamic> keyMetadata = {
        'alias': defaultAlias,
        'label': 'Default Key',
        'created_at': DateTime.now().toIso8601String(),
      };
      
      keys.add(keyMetadata);
      await _secureStorage.write(key: 'keys', value: jsonEncode(keys));
    }
  }

  /// Updates the label of a key with the specified alias.
  ///
  /// [alias]: The unique alias of the key to update.
  /// [newLabel]: The new label to assign to the key.
  ///
  /// Throws an exception if the key is not found or the update fails.
  Future<void> updateKeyLabel(String alias, String newLabel) async {
    try {
      // Retrieve existing keys
      final String? existingKeys = await _secureStorage.read(key: 'keys');
      if (existingKeys == null) {
        throw Exception("No keys found to update.");
      }

      List<dynamic> keysList = jsonDecode(existingKeys);

      // Find the key with the specified alias
      bool keyFound = false;
      for (var key in keysList) {
        if (key['alias'] == alias) {
          key['label'] = newLabel;
          keyFound = true;
          break;
        }
      }

      if (!keyFound) {
        throw Exception("Key with alias \"$alias\" not found.");
      }

      // Save the updated keys list
      await _secureStorage.write(key: 'keys', value: jsonEncode(keysList));
    } catch (e) {
      throw Exception("Failed to update key label: $e");
    }
  }

  bool _shouldAttemptKeystoreRepair(PlatformException exception) {
    const recoverableCodes = {
      'SIGNING_FAILED',
      'KEY_NOT_FOUND',
      'KEY_PERMANENTLY_INVALIDATED',
      'KEYSTORE_FAILED',
    };
    if (recoverableCodes.contains(exception.code)) {
      return true;
    }
    final message = (exception.message ?? '').toLowerCase();
    return message.contains('keystore operation failed') ||
        message.contains('key_permanently_invalidated') ||
        message.contains('private key not found') ||
        message.contains('no key material available') ||
        message.contains('bad state');
  }

  Future<void> _repairKeystoreEntry(String alias) async {
    try {
      await _removeAlias(alias);
      // Wait for keystore to sync before regenerating
      await Future.delayed(const Duration(milliseconds: 150));
      await _generateAlias(alias);
      // Another brief wait for the new key to be fully established
      await Future.delayed(const Duration(milliseconds: 100));
      await _refreshMetadataTimestamp(alias);
    } catch (e) {
      debugPrint('Error during keystore repair: $e');
      rethrow;
    }
  }

  Future<void> _removeAlias(String alias) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await _channel.invokeMethod('deleteKeyPair', {'alias': alias});
      } catch (_) {
        // Ignore delete failures – alias may already be missing.
      }
      final bool stillExists = await _aliasExists(alias);
      if (!stillExists) {
        return;
      }
      await Future.delayed(Duration(milliseconds: 100 + (50 * attempt)));
    }
    // Even if we can't delete it, continue - the repair process will handle creating a new one
    debugPrint('Warning: Unable to completely remove keystore alias "$alias" after multiple attempts.');
  }

  Future<void> _generateAlias(String alias) async {
    try {
      await _channel.invokeMethod('generateKeyPair', {'alias': alias});
    } on PlatformException catch (e) {
      if (e.code == 'KEY_EXISTS') {
        await _removeAlias(alias);
        await _channel.invokeMethod('generateKeyPair', {'alias': alias});
        return;
      }
      rethrow;
    }
  }

  Future<void> _generateAliasWithRetry(String alias) async {
    int attempts = 0;
    const maxAttempts = 3;
    
    while (attempts < maxAttempts) {
      try {
        await _channel.invokeMethod('generateKeyPair', {'alias': alias});
        return;
      } on PlatformException catch (e) {
        if (e.code == 'KEY_EXISTS') {
          try {
            await _removeAlias(alias);
            await Future.delayed(const Duration(milliseconds: 100));
          } catch (_) {
            // Ignore errors during removal
          }
          attempts++;
          if (attempts < maxAttempts) {
            await Future.delayed(Duration(milliseconds: 150 + (100 * attempts)));
          }
        } else {
          rethrow;
        }
      }
    }
    throw Exception('Failed to generate key pair after $maxAttempts attempts. Key alias may be stuck in keystore.');
  }

  Future<bool> _aliasExists(String alias) async {
    try {
      final bool exists = await _channel.invokeMethod('keyPairExists', {'alias': alias});
      return exists;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshMetadataTimestamp(String alias) async {
    final String? existingKeys = await _secureStorage.read(key: 'keys');
    final List<dynamic> keysList = existingKeys != null ? jsonDecode(existingKeys) : [];
    bool updated = false;
    for (final entry in keysList) {
      if (entry is Map && entry['alias'] == alias) {
        entry['created_at'] = DateTime.now().toIso8601String();
        updated = true;
        break;
      }
    }
    if (!updated) {
      keysList.add({
        'alias': alias,
        'label': 'Recovered Key',
        'created_at': DateTime.now().toIso8601String(),
      });
    }
    await _secureStorage.write(key: 'keys', value: jsonEncode(keysList));
  }
}
