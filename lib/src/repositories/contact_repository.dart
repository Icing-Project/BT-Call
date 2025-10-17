import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/contact.dart';

class ContactRepository {
  ContactRepository({SharedPreferences? preferences})
      : _preferencesFuture = preferences != null
            ? Future.value(preferences)
            : SharedPreferences.getInstance();

  static const String _storageKey = 'btcalls_contacts';

  final Future<SharedPreferences> _preferencesFuture;

  Future<List<Contact>> getContacts() async {
    final prefs = await _preferencesFuture;
    final stored = prefs.getStringList(_storageKey) ?? const [];
    return stored
        .map((entry) => Contact.fromJson(jsonDecode(entry) as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<void> saveContacts(List<Contact> contacts) async {
    final prefs = await _preferencesFuture;
    final encoded = contacts
        .map((contact) => jsonEncode(contact.toJson()))
        .toList(growable: false);
    await prefs.setStringList(_storageKey, encoded);
  }

  Future<void> addContact(Contact contact, {bool replace = false}) async {
    final contacts = await getContacts();
    final existingIndex = contacts.indexWhere(
      (item) => _isSameContact(item, contact),
    );
    if (existingIndex >= 0) {
      final existing = contacts[existingIndex];
      contacts[existingIndex] = _mergeContacts(existing, contact, replaceExisting: replace);
    } else {
      contacts.add(contact);
    }
    await saveContacts(contacts);
  }

  Future<void> removeContact(Contact contact) async {
    final contacts = await getContacts();
    contacts.removeWhere((item) => _isSameContact(item, contact));
    await saveContacts(contacts);
  }

  bool _isSameContact(Contact a, Contact b) {
    if (a.publicKey.isNotEmpty && b.publicKey.isNotEmpty && a.publicKey == b.publicKey) {
      return true;
    }
    final hintA = a.discoveryHint.toUpperCase();
    final hintB = b.discoveryHint.toUpperCase();
    if (hintA.isNotEmpty && hintB.isNotEmpty && hintA == hintB) {
      return true;
    }
    return false;
  }

  Contact _mergeContacts(Contact existing, Contact incoming, {required bool replaceExisting}) {
    if (replaceExisting) {
      return incoming.copyWith(
        createdAt: existing.createdAt.isBefore(incoming.createdAt)
            ? existing.createdAt
            : incoming.createdAt,
        lastSeen: incoming.lastSeen ?? existing.lastSeen,
        lastKnownDeviceName: incoming.lastKnownDeviceName ?? existing.lastKnownDeviceName,
      );
    }
    final normalizedName = incoming.name.trim().isNotEmpty && incoming.name.trim() != 'Unknown'
        ? incoming.name.trim()
        : existing.name;
    final normalizedHint = incoming.discoveryHint.isNotEmpty
        ? incoming.discoveryHint
        : existing.discoveryHint;
    final normalizedKey = incoming.publicKey.isNotEmpty
        ? incoming.publicKey
        : existing.publicKey;
    final lastSeen = incoming.lastSeen ?? existing.lastSeen;
    final deviceName = incoming.lastKnownDeviceName?.isNotEmpty == true
        ? incoming.lastKnownDeviceName
        : existing.lastKnownDeviceName;
    return existing.copyWith(
      name: normalizedName,
      discoveryHint: normalizedHint,
      publicKey: normalizedKey,
      lastSeen: lastSeen,
      lastKnownDeviceName: deviceName,
    );
  }
}
