import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class AsymmetricCryptoService {
  static const MethodChannel _channel = MethodChannel('com.example.keystore');
  final FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  final String _aliasPrefix = 'icing_';
  final Uuid _uuid = Uuid();

  /// Generates an ED25519 key pair with a unique alias and stores its metadata.
  Future<String> generateKeyPair({String? label}) async {
    try {
      // Generate a unique identifier for the key
      final String uuid = _uuid.v4();
      final String alias = '$_aliasPrefix$uuid';

      // Invoke native method to generate the key pair
      await _channel.invokeMethod('generateKeyPair', {'alias': alias});

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
    } on PlatformException catch (e) {
      throw Exception("Failed to generate key pair: ${e.message}");
    }
  }

  /// Signs data using the specified key alias.
  Future<String> signData(String alias, String data) async {
    try {
      final String signature = await _channel.invokeMethod('signData', {
        'alias': alias,
        'data': data,
      });
      return signature;
    } on PlatformException catch (e) {
      throw Exception("Failed to sign data with alias '$alias': ${e.message}");
    }
  }

  /// Retrieves the public key for the specified alias.
  Future<String> getPublicKey(String alias) async {
    try {
      final String publicKey = await _channel.invokeMethod('getPublicKey', {
        'alias': alias,
      });
      return publicKey;
    } on PlatformException catch (e) {
      throw Exception("Failed to retrieve public key: ${e.message}");
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
        print("No keys found");
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
    try {
      final bool exists = await _channel.invokeMethod('keyPairExists', {'alias': alias});
      return exists;
    } on PlatformException catch (e) {
      throw Exception("Failed to check key pair existence: ${e.message}");
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
}
