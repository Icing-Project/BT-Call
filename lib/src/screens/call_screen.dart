import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../providers/bluetooth_provider.dart';

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
  bool _isNavigatingBack = false; // Flag to prevent multiple navigation attempts

  @override
  void initState() {
    super.initState();
    
    // Listen for call ended events to automatically close the screen
    final btProvider = Provider.of<BluetoothProvider>(context, listen: false);
    btProvider.addListener(_onCallStateChanged);
  }
  
  @override
  void dispose() {
    // Remove listener to prevent memory leaks
    try {
      final btProvider = Provider.of<BluetoothProvider>(context, listen: false);
      btProvider.removeListener(_onCallStateChanged);
    } catch (e) {
      // Ignore errors if provider is already disposed
    }
    super.dispose();
  }
  
  void _onCallStateChanged() {
    if (!mounted || _isNavigatingBack) return; // Prevent multiple navigation attempts
    
    final btProvider = Provider.of<BluetoothProvider>(context, listen: false);
    
    // Close call screen if call ended by remote device or connection lost
    if (!btProvider.isConnected && 
        (btProvider.status.contains('call ended') || 
         btProvider.status.contains('stopped') || 
         btProvider.status.contains('Error') ||
         btProvider.status.contains('ending call'))) {
      _isNavigatingBack = true; // Set flag before navigation
      // Navigate immediately
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final btProvider = context.watch<BluetoothProvider>();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _showEndCallDialog(context);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              // Header with connection status
              Container(
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
                      widget.deviceName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    if (widget.aliasSummary?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4.0),
                        child: Text(
                          'Alias: ${widget.aliasSummary}',
                          style: TextStyle(
                            color: Colors.blue[200],
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    Text(
                        'Address: ${widget.deviceAddress}',
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 14,
                      ),
                    ),
                    if (widget.publicKey?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text(
                          _shortenKey(widget.publicKey!),
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
              ),
              
              // Spacer to center the avatar
              const Spacer(),
              
              // Large device avatar
              Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.blue[400]!,
                      Colors.blue[600]!,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blue.withOpacity(0.3),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Icon(
                  FontAwesomeIcons.mobileScreen,
                  color: Colors.white,
                  size: 80,
                ),
              ),
              
              const Spacer(),
              
              // Call status indicator
              Container(
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
                    Text(
                      btProvider.status,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 40),
              
              // Encryption status indicator
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                margin: const EdgeInsets.symmetric(horizontal: 48),
                decoration: BoxDecoration(
                  color: (btProvider.decryptEnabled && btProvider.encryptEnabled) 
                      ? Colors.green[900] 
                      : (btProvider.decryptEnabled || btProvider.encryptEnabled) 
                          ? Colors.yellow[900] 
                          : Colors.orange[900],
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      (btProvider.decryptEnabled && btProvider.encryptEnabled) 
                          ? FontAwesomeIcons.shield 
                          : FontAwesomeIcons.triangleExclamation,
                      color: (btProvider.decryptEnabled && btProvider.encryptEnabled) 
                          ? Colors.green[300] 
                          : (btProvider.decryptEnabled || btProvider.encryptEnabled) 
                              ? Colors.yellow[300] 
                              : Colors.orange[300],
                      size: 16,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      (btProvider.decryptEnabled && btProvider.encryptEnabled) 
                          ? 'Audio Encrypted' 
                          : (btProvider.decryptEnabled || btProvider.encryptEnabled) 
                              ? 'Partial Encryption' 
                              : 'Audio Not Encrypted',
                      style: TextStyle(
                        color: (btProvider.decryptEnabled && btProvider.encryptEnabled) 
                            ? Colors.green[300] 
                            : (btProvider.decryptEnabled || btProvider.encryptEnabled) 
                                ? Colors.yellow[300] 
                                : Colors.orange[300],
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 20),
              
              // Control buttons
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Encrypt toggle button
                    _buildCallButton(
                      icon: btProvider.encryptEnabled 
                          ? FontAwesomeIcons.key 
                          : FontAwesomeIcons.unlock,
                      backgroundColor: btProvider.encryptEnabled 
                          ? Colors.blue[600]! 
                          : Colors.grey[600]!,
                      onPressed: () => _performSelection(() => btProvider.toggleEncrypt(!btProvider.encryptEnabled)),
                    ),
                    
                    // Decrypt toggle button
                    _buildCallButton(
                      icon: btProvider.decryptEnabled 
                          ? FontAwesomeIcons.lock 
                          : FontAwesomeIcons.lockOpen,
                      backgroundColor: btProvider.decryptEnabled 
                          ? Colors.green[600]! 
                          : Colors.orange[600]!,
                      onPressed: () => _performSelection(() => btProvider.toggleDecrypt(!btProvider.decryptEnabled)),
                    ),
                    
                    // Hang up button
                    _buildCallButton(
                      icon: FontAwesomeIcons.phoneSlash,
                      backgroundColor: Colors.red[600]!,
                      onPressed: () => _performDestructive(() => _hangUp(context)),
                    ),
                    
                    // Speaker button
                    _buildCallButton(
                      icon: btProvider.speakerOn
                          ? FontAwesomeIcons.volumeHigh
                          : FontAwesomeIcons.volumeXmark,
                      backgroundColor: btProvider.speakerOn
                          ? Colors.blue[600]! 
                          : Colors.grey[800]!,
                      onPressed: () => _performSelection(() => btProvider.toggleSpeaker(!btProvider.speakerOn)),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 60),
            ],
          ),
        ),
      ),
    );
  }

  void _performSelection(VoidCallback action) {
    HapticFeedback.selectionClick();
    action();
  }

  void _performDestructive(VoidCallback action) {
    HapticFeedback.mediumImpact();
    action();
  }

  Widget _buildCallButton({
    required IconData icon,
    required Color backgroundColor,
    required VoidCallback onPressed,
  }) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: backgroundColor.withOpacity(0.3),
            blurRadius: 15,
            spreadRadius: 2,
          ),
        ],
      ),
      child: FloatingActionButton(
        heroTag: icon.hashCode, // Unique hero tag for each button
        onPressed: onPressed,
        backgroundColor: backgroundColor,
        elevation: 0,
        child: Icon(
          icon,
          color: Colors.white,
          size: 24,
        ),
      ),
    );
  }

  void _showEndCallDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End Call'),
        content: const Text('Are you sure you want to end the call?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _hangUp(context);
            },
            child: const Text('End Call'),
          ),
        ],
      ),
    );
  }

  void _hangUp(BuildContext context) {
    if (_isNavigatingBack) return; // Prevent multiple calls
    
    _isNavigatingBack = true;
    final btProvider = Provider.of<BluetoothProvider>(context, listen: false);
    btProvider.endCall(); // This will trigger status change
    
    // Navigate back immediately
    Navigator.of(context).pop();
  }

  String _shortenKey(String key) {
    if (key.length <= 16) return key;
    return '${key.substring(0, 16)}…';
  }
}
