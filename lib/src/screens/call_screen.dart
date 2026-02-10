import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../providers/bluetooth_provider.dart';
import '../providers/settings_provider.dart';

class CallScreen extends StatefulWidget {
  final String deviceName;
  final String deviceAddress;
  final String? aliasSummary;
  final String? publicKey;

  const CallScreen({
    Key? key,
    required this.deviceName,
    required this.deviceAddress,
    this.aliasSummary,
    this.publicKey,
  }) : super(key: key);

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _isNavigatingBack = false;

  @override
  void initState() {
    super.initState();
    final btProvider = Provider.of<BluetoothProvider>(context, listen: false);
    btProvider.addListener(_onCallStateChanged);
  }

  @override
  void dispose() {
    try {
      final btProvider = Provider.of<BluetoothProvider>(context, listen: false);
      btProvider.removeListener(_onCallStateChanged);
    } catch (e) {
      // Ignore errors if provider is already disposed
    }
    super.dispose();
  }

  void _onCallStateChanged() {
    if (!mounted || _isNavigatingBack) return;

    final btProvider = Provider.of<BluetoothProvider>(context, listen: false);

    if (!btProvider.isConnected &&
        (btProvider.status.contains('call ended') ||
            btProvider.status.contains('stopped') ||
            btProvider.status.contains('Error') ||
            btProvider.status.contains('ending call'))) {
      _isNavigatingBack = true;
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  void _showEndCallDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End Call'),
        content: const Text('Are you sure you want to end the call?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _hangUp();
            },
            child: const Text('End Call'),
          ),
        ],
      ),
    );
  }

  void _hangUp() {
    if (_isNavigatingBack) return;
    _isNavigatingBack = true;
    final btProvider = Provider.of<BluetoothProvider>(context, listen: false);
    btProvider.endCall();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _showEndCallDialog();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              // Header - Static content
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _CallHeader(
                        deviceName: widget.deviceName,
                        deviceAddress: widget.deviceAddress,
                        aliasSummary: widget.aliasSummary,
                        publicKey: widget.publicKey,
                      ),
                      const SizedBox(height: 6),
                      const _DeviceAvatar(),
                      const SizedBox(height: 32),
                      const _StatusIndicator(),
                      const SizedBox(height: 16),
                      const _EncryptionStatusBadge(),
                      const _VerbosePanel(),
                    ],
                  ),
                ),
              ),
              // Fixed bottom control area - NOT in scroll
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 24,
                  horizontal: 16,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _EncryptButton(),
                    _DecryptButton(),
                    _HangUpButton(onPressed: _hangUp),
                    _MuteButton(),
                    _SpeakerButton(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// STATIC HEADER WIDGET
// =============================================================================

class _CallHeader extends StatelessWidget {
  final String deviceName;
  final String deviceAddress;
  final String? aliasSummary;
  final String? publicKey;

  const _CallHeader({
    required this.deviceName,
    required this.deviceAddress,
    this.aliasSummary,
    this.publicKey,
  });

  String _shortenKey(String key) {
    if (key.length <= 16) return key;
    return '${key.substring(0, 16)}…';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Text(
            'Connected',
            style: TextStyle(
              color: Colors.green[300],
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            deviceName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          // if (aliasSummary?.isNotEmpty == true)
          //   Padding(
          //     padding: const EdgeInsets.only(bottom: 4.0),
          //     child: Text(
          //       'Alias: $aliasSummary',
          //       style: TextStyle(
          //         color: Colors.blue[200],
          //         fontSize: 16,
          //         fontWeight: FontWeight.w500,
          //       ),
          //       textAlign: TextAlign.center,
          //     ),
          //   ),
          Text(
            'Address: $deviceAddress',
            style: TextStyle(color: Colors.grey[400], fontSize: 14),
          ),
          if (publicKey?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: Text(
                _shortenKey(publicKey!),
                style: TextStyle(
                  color: Colors.blue[200],
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// STATIC AVATAR WIDGET
// =============================================================================

class _DeviceAvatar extends StatelessWidget {
  const _DeviceAvatar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      height: 150,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.blue[400]!, Colors.blue[600]!],
        ),
      ),
      child: const Icon(
        FontAwesomeIcons.mobileScreen,
        color: Colors.white,
        size: 60,
      ),
    );
  }
}

// =============================================================================
// STATUS INDICATOR
// =============================================================================

class _StatusIndicator extends StatelessWidget {
  const _StatusIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      margin: const EdgeInsets.symmetric(horizontal: 48),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: const BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Selector<BluetoothProvider, String>(
            selector: (_, p) => p.status,
            builder: (_, status, __) => Text(
              status,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// ENCRYPTION STATUS BADGE
// =============================================================================

class _EncryptionStatusBadge extends StatelessWidget {
  const _EncryptionStatusBadge();

  @override
  Widget build(BuildContext context) {
    return Selector<BluetoothProvider, ({bool enc, bool dec})>(
      selector: (_, p) => (enc: p.encryptEnabled, dec: p.decryptEnabled),
      builder: (_, state, __) {
        final both = state.enc && state.dec;
        final any = state.enc || state.dec;

        final bgColor = both
            ? Colors.green[900]
            : any
            ? Colors.yellow[900]
            : Colors.orange[900];

        final icon = both
            ? FontAwesomeIcons.shield
            : FontAwesomeIcons.triangleExclamation;

        final iconColor = both
            ? Colors.green[300]
            : any
            ? Colors.yellow[300]
            : Colors.orange[300];

        final text = both
            ? 'Audio Encrypted'
            : any
            ? 'Partial Encryption'
            : 'Audio Not Encrypted';

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          margin: const EdgeInsets.symmetric(horizontal: 48),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: iconColor, size: 16),
              const SizedBox(width: 12),
              Text(
                text,
                style: TextStyle(
                  color: iconColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// =============================================================================
// VERBOSE PANEL
// =============================================================================

class _VerbosePanel extends StatelessWidget {
  const _VerbosePanel();

  Color _getLogColor(String log) {
    if (log.contains('❌') || log.contains('Error')) return Colors.red[300]!;
    if (log.contains('⚠️')) return Colors.orange[300]!;
    if (log.contains('✓')) return Colors.green[300]!;
    if (log.contains('🔐') || log.contains('🔊')) return Colors.blue[300]!;
    if (log.contains('📱')) return Colors.cyan[300]!;
    return Colors.grey[300]!;
  }

  @override
  Widget build(BuildContext context) {
    return Selector<SettingsProvider, bool>(
      selector: (_, s) => s.verboseMode,
      builder: (_, verbose, __) {
        if (!verbose) return const SizedBox.shrink();

        return Selector<BluetoothProvider, List<String>>(
          selector: (_, p) => p.verboseLogs,
          shouldRebuild: (prev, next) => prev != next,
          builder: (_, logs, __) {
            if (logs.isEmpty) return const SizedBox.shrink();

            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[700]!, width: 1),
              ),
              constraints: const BoxConstraints(maxHeight: 150),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Icons.terminal, color: Colors.grey[400], size: 16),
                      const SizedBox(width: 8),
                      Text(
                        'Call Events',
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 12, color: Colors.grey),
                  Expanded(
                    child: ListView.builder(
                      shrinkWrap: true,
                      reverse: true,
                      itemCount: logs.length,
                      itemBuilder: (_, index) {
                        final log = logs[logs.length - 1 - index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            log,
                            style: TextStyle(
                              color: _getLogColor(log),
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// =============================================================================
// SIMPLE CALL BUTTON - No FloatingActionButton, no shadows with opacity
// =============================================================================

class _SimpleCallButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _SimpleCallButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 56,
          height: 56,
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

// =============================================================================
// BUTTON WIDGETS - Each uses ValueListenableBuilder pattern
// =============================================================================

class _EncryptButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Selector<BluetoothProvider, bool>(
      selector: (_, p) => p.encryptEnabled,
      builder: (ctx, enabled, __) => _SimpleCallButton(
        icon: enabled ? FontAwesomeIcons.key : FontAwesomeIcons.unlock,
        color: enabled ? Colors.blue[600]! : Colors.grey[600]!,
        onTap: () {
          HapticFeedback.selectionClick();
          ctx.read<BluetoothProvider>().toggleEncrypt(!enabled);
        },
      ),
    );
  }
}

class _DecryptButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Selector<BluetoothProvider, bool>(
      selector: (_, p) => p.decryptEnabled,
      builder: (ctx, enabled, __) => _SimpleCallButton(
        icon: enabled ? FontAwesomeIcons.lock : FontAwesomeIcons.lockOpen,
        color: enabled ? Colors.green[600]! : Colors.orange[600]!,
        onTap: () {
          HapticFeedback.selectionClick();
          ctx.read<BluetoothProvider>().toggleDecrypt(!enabled);
        },
      ),
    );
  }
}

class _HangUpButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _HangUpButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return _SimpleCallButton(
      icon: FontAwesomeIcons.phoneSlash,
      color: Colors.red[600]!,
      onTap: () {
        HapticFeedback.mediumImpact();
        onPressed();
      },
    );
  }
}

class _MuteButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Selector<BluetoothProvider, bool>(
      selector: (_, p) => p.muteEnabled,
      builder: (ctx, muted, __) => _SimpleCallButton(
        icon: muted
            ? FontAwesomeIcons.microphoneSlash
            : FontAwesomeIcons.microphone,
        color: muted ? Colors.grey[600]! : Colors.blue[600]!,
        onTap: () {
          HapticFeedback.selectionClick();
          ctx.read<BluetoothProvider>().toggleMute(!muted);
        },
      ),
    );
  }
}

class _SpeakerButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Selector<BluetoothProvider, bool>(
      selector: (_, p) => p.speakerOn,
      builder: (ctx, on, __) => _SimpleCallButton(
        icon: on ? FontAwesomeIcons.volumeHigh : FontAwesomeIcons.volumeXmark,
        color: on ? Colors.blue[600]! : Colors.grey[800]!,
        onTap: () {
          HapticFeedback.selectionClick();
          ctx.read<BluetoothProvider>().toggleSpeaker(!on);
        },
      ),
    );
  }
}
