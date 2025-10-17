import 'package:flutter/material.dart';

import '../models/contact.dart';
import '../repositories/contact_repository.dart';

class ContactsProvider extends ChangeNotifier {
  ContactsProvider({ContactRepository? repository})
      : _repository = repository ?? ContactRepository() {
    _loadContacts();
  }

  final ContactRepository _repository;

  final List<Contact> _contacts = [];
  bool _isLoading = true;

  List<Contact> get contacts => List.unmodifiable(_contacts);
  bool get isLoading => _isLoading;
  bool get isEmpty => _contacts.isEmpty && !_isLoading;

  Future<void> _loadContacts() async {
    try {
      final loaded = await _repository.getContacts();
      _contacts
        ..clear()
        ..addAll(loaded);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> addContact(Contact contact, {bool replaceExisting = false}) async {
    final normalized = _normalizeContact(contact);
    final existingIndex = _contacts.indexWhere((item) => _isSameContact(item, normalized));
    if (existingIndex >= 0) {
      final existing = _contacts[existingIndex];
      final merged = _mergeContacts(existing, normalized, replaceExisting: replaceExisting);
      final changed = !_areContactsEqual(existing, merged);
      if (changed) {
        _contacts[existingIndex] = merged;
        await _persist();
      }
      return changed;
    } else {
      _contacts.add(normalized);
      await _persist();
      return true;
    }
  }

  Future<void> removeContact(Contact contact) async {
    _contacts.removeWhere((item) => _isSameContact(item, contact));
    await _persist();
  }

  List<Contact> contactsForDiscoveryHint(String hint) {
    final normalized = hint.toUpperCase();
    if (normalized.isEmpty) return const [];
    return _contacts
        .where((contact) => contact.discoveryHint.toUpperCase() == normalized)
        .toList(growable: false);
  }

  Contact? contactForDiscoveryHint(String hint) {
    final normalized = hint.toUpperCase();
    if (normalized.isEmpty) return null;
    for (final contact in _contacts) {
      if (contact.discoveryHint.toUpperCase() == normalized) {
        return contact;
      }
    }
    return null;
  }

  Contact? contactForPublicKey(String publicKey) {
    if (publicKey.isEmpty) return null;
    for (final contact in _contacts) {
      if (contact.publicKey == publicKey) {
        return contact;
      }
    }
    return null;
  }

  Future<Contact?> markContactSeenByHint({
    required String discoveryHint,
    String? deviceName,
  }) async {
    final normalizedHint = discoveryHint.toUpperCase();
    if (normalizedHint.isEmpty) return null;
    final index = _contacts.indexWhere(
      (contact) => contact.discoveryHint.toUpperCase() == normalizedHint,
    );
    if (index < 0) return null;
    final existing = _contacts[index];
    final trimmedName = deviceName?.trim();
    final updated = existing.copyWith(
      lastSeen: DateTime.now(),
      lastKnownDeviceName: trimmedName?.isNotEmpty == true
          ? trimmedName
          : existing.lastKnownDeviceName,
    );
    if (_areContactsEqual(existing, updated)) {
      return existing;
    }
    _contacts[index] = updated;
    await _persist();
    return updated;
  }

  Contact _mergeContacts(Contact base, Contact incoming, {required bool replaceExisting}) {
    if (replaceExisting) {
      return incoming.copyWith(
        createdAt: base.createdAt.isBefore(incoming.createdAt) ? base.createdAt : incoming.createdAt,
        lastSeen: incoming.lastSeen ?? base.lastSeen,
        lastKnownDeviceName: incoming.lastKnownDeviceName ?? base.lastKnownDeviceName,
      );
    }
    final name = incoming.name.trim().isNotEmpty && incoming.name.trim() != 'Unknown'
        ? incoming.name.trim()
        : base.name;
    final discoveryHint = incoming.discoveryHint.isNotEmpty
        ? incoming.discoveryHint
        : base.discoveryHint;
    final publicKey = incoming.publicKey.isNotEmpty ? incoming.publicKey : base.publicKey;
    final lastSeen = incoming.lastSeen ?? base.lastSeen;
    final deviceName = incoming.lastKnownDeviceName?.isNotEmpty == true
        ? incoming.lastKnownDeviceName
        : base.lastKnownDeviceName;

    return base.copyWith(
      name: name,
      discoveryHint: discoveryHint,
      publicKey: publicKey,
      lastSeen: lastSeen,
      lastKnownDeviceName: deviceName,
    );
  }

  Contact _normalizeContact(Contact contact) {
    return contact.copyWith(
      discoveryHint: contact.discoveryHint.toUpperCase(),
      name: contact.name.trim().isEmpty ? 'Unknown' : contact.name.trim(),
    );
  }

  bool _isSameContact(Contact a, Contact b) {
    if (a.publicKey.isNotEmpty && a.publicKey == b.publicKey) {
      return true;
    }
    final hintA = a.discoveryHint.toUpperCase();
    final hintB = b.discoveryHint.toUpperCase();
    if (hintA.isNotEmpty && hintB.isNotEmpty && hintA == hintB) {
      return true;
    }
    return false;
  }

  bool _areContactsEqual(Contact a, Contact b) {
    return a.name == b.name &&
        a.publicKey == b.publicKey &&
        a.createdAt == b.createdAt &&
        a.discoveryHint == b.discoveryHint &&
        a.lastSeen == b.lastSeen &&
        a.lastKnownDeviceName == b.lastKnownDeviceName;
  }

  Future<void> _persist() async {
    await _repository.saveContacts(_contacts);
    notifyListeners();
  }
}
