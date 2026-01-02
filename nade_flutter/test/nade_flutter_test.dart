import 'package:flutter_test/flutter_test.dart';
import 'package:nade_flutter/nade_flutter.dart';

void main() {
  test('setEventHandler stores callback', () {
    expect(() => Nade.setEventHandler((_) {}), returnsNormally);
  });
}
