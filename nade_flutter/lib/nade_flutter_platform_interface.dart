import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'nade_flutter_method_channel.dart';

abstract class NadeFlutterPlatform extends PlatformInterface {
  /// Constructs a NadeFlutterPlatform.
  NadeFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static NadeFlutterPlatform _instance = MethodChannelNadeFlutter();

  /// The default instance of [NadeFlutterPlatform] to use.
  ///
  /// Defaults to [MethodChannelNadeFlutter].
  static NadeFlutterPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [NadeFlutterPlatform] when
  /// they register themselves.
  static set instance(NadeFlutterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
