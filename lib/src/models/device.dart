class Device {
  final String name;
  final String address;
  final String discoveryHint;

  Device({
    required this.name,
    required this.address,
    this.discoveryHint = '',
  });
}
