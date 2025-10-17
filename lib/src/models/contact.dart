import 'dart:convert';

class Contact {
  const Contact({
    required this.name,
    required this.publicKey,
    required this.createdAt,
    required this.discoveryHint,
    this.lastSeen,
    this.lastKnownDeviceName,
  });

  final String name;
  final String publicKey;
  final DateTime createdAt;
  final String discoveryHint;
  final DateTime? lastSeen;
  final String? lastKnownDeviceName;

  Contact copyWith({
    String? name,
    String? publicKey,
    DateTime? createdAt,
    String? discoveryHint,
    DateTime? lastSeen,
    bool clearLastSeen = false,
    String? lastKnownDeviceName,
    bool clearLastKnownDeviceName = false,
  }) {
    return Contact(
      name: name ?? this.name,
      publicKey: publicKey ?? this.publicKey,
      createdAt: createdAt ?? this.createdAt,
      discoveryHint: discoveryHint ?? this.discoveryHint,
      lastSeen: clearLastSeen ? null : (lastSeen ?? this.lastSeen),
      lastKnownDeviceName: clearLastKnownDeviceName
          ? null
          : (lastKnownDeviceName ?? this.lastKnownDeviceName),
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'name': name,
      'publicKey': publicKey,
      'createdAt': createdAt.toIso8601String(),
      'discoveryHint': discoveryHint,
    };
    if (lastSeen != null) {
      map['lastSeen'] = lastSeen!.toIso8601String();
    }
    if (lastKnownDeviceName != null && lastKnownDeviceName!.isNotEmpty) {
      map['lastKnownDeviceName'] = lastKnownDeviceName;
    }
    return map;
  }

  static Contact fromJson(Map<String, dynamic> json) {
    final createdAt = _parseDate(json['createdAt']) ?? DateTime.now();
    final lastSeen = _parseDate(json['lastSeen']);
    return Contact(
      name: json['name'] as String? ?? 'Unknown',
      publicKey: json['publicKey'] as String? ?? '',
      createdAt: createdAt,
      discoveryHint: (json['discoveryHint'] as String? ?? '').toUpperCase(),
      lastSeen: lastSeen,
      lastKnownDeviceName: json['lastKnownDeviceName'] as String?,
    );
  }

  String toEncodedString() => jsonEncode(toJson());

  static Contact fromEncodedString(String encoded) =>
      Contact.fromJson(jsonDecode(encoded) as Map<String, dynamic>);

  static DateTime? _parseDate(dynamic value) {
    if (value is DateTime) {
      return value;
    }
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }
}
