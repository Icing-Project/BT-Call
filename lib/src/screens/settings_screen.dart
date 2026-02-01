import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';

/// Settings screen with verbose mode toggle for call operations
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          // Verbose Mode Section
          _buildSectionHeader(context, 'Call Operations'),
          SwitchListTile(
            title: const Text('Verbose Mode'),
            subtitle: const Text(
              'Show detailed information during calls: handshake status, '
              'server/client mode, encryption state, and connection events.',
            ),
            value: settings.verboseMode,
            onChanged: (value) => settings.setVerboseMode(value),
            secondary: Icon(
              Icons.terminal,
              color: settings.verboseMode 
                  ? Theme.of(context).colorScheme.primary 
                  : null,
            ),
          ),
          const Divider(),
          
          // Info Section
          _buildSectionHeader(context, 'About Verbose Mode'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, 
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        const Text(
                          'What is Verbose Mode?',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'When enabled, verbose mode displays real-time information '
                      'about call operations on the call screen. This includes:',
                    ),
                    const SizedBox(height: 8),
                    _buildBulletPoint('• Handshake progress and completion'),
                    _buildBulletPoint('• Your device role (Server or Client)'),
                    _buildBulletPoint('• Encryption/decryption status'),
                    _buildBulletPoint('• Key exchange events'),
                    _buildBulletPoint('• Connection state changes'),
                    const SizedBox(height: 8),
                    const Text(
                      'This is useful for debugging connection issues or '
                      'understanding how the secure connection is established.',
                      style: TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
  
  Widget _buildBulletPoint(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 8.0, top: 2.0),
      child: Text(text),
    );
  }
}
