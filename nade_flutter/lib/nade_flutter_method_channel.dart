import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'nade_flutter_platform_interface.dart';

/// An implementation of [NadeFlutterPlatform] that uses method channels.
class MethodChannelNadeFlutter extends NadeFlutterPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('nade_flutter');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
