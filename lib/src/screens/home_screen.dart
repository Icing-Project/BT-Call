import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../providers/bluetooth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/theme_provider.dart';
import '../models/device.dart';
import 'call_screen.dart';
import 'contacts_screen.dart';
import 'key_management.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {


  // Manual connect controller
  final TextEditingController _manualController = TextEditingController();
  bool _isMacValid = false;
  final RegExp _macRegExp = RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$');
  
  @override
  void initState() {
    super.initState();
    _manualController.addListener(() {
      final valid = _macRegExp.hasMatch(_manualController.text.trim());
      if (valid != _isMacValid) setState(() => _isMacValid = valid);
    });
    
    // Listen for connection changes to navigate to call screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final btProvider = context.read<BluetoothProvider>();
      btProvider.addListener(_onConnectionChanged);
    });
  }
  
  void _onConnectionChanged() {
    final btProvider = context.read<BluetoothProvider>();
    _scheduleMessageFlush(btProvider);
    
    // Navigate to call screen when connected
    if (btProvider.isConnected && btProvider.connectedDevice != null) {
      final contactsProvider = context.read<ContactsProvider>();
      final device = btProvider.connectedDevice!;
      final matches = device.discoveryHint.isNotEmpty
          ? contactsProvider.contactsForDiscoveryHint(device.discoveryHint)
          : const [];
      final aliasSummary = matches.isEmpty
          ? null
          : matches.map((contact) => contact.name).join(', ');
      final keyPreview = matches.isEmpty ? '' : matches.first.publicKey;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => CallScreen(
            deviceName: device.name,
            deviceAddress: device.address,
            aliasSummary: aliasSummary,
            publicKey: keyPreview,
          ),
        ),
      );
    }
  }
    void _scheduleMessageFlush(BluetoothProvider provider) {
      if (!mounted || !provider.hasPendingMessages) return;
      final messages = provider.takeMessageBatch();
      if (messages.isEmpty) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final theme = Theme.of(context);
        for (var i = 0; i < messages.length; i++) {
          final message = messages[i];
          Future.delayed(Duration(milliseconds: i * 2600), () {
            if (!mounted) return;
            Color background;
            switch (message.type) {
              case UXMessageType.info:
                background = theme.colorScheme.primary;
                break;
              case UXMessageType.warning:
                background = theme.colorScheme.secondary;
                break;
              case UXMessageType.error:
                background = theme.colorScheme.error;
                break;
            }
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(message.text),
                  backgroundColor: background,
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(milliseconds: 2200),
                ),
              );
          });
        }
      });
    }

  @override
  void dispose() {
    _manualController.dispose();
    // Remove listener to prevent memory leaks
    final btProvider = context.read<BluetoothProvider>();
    btProvider.removeListener(_onConnectionChanged);
    super.dispose();
  }
  
  // Show a dialog to manually enter a MAC address when auto scan fails
  void _showManualConnectDialog() {
    _manualController.clear();
    setState(() => _isMacValid = false);
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Manual Connect'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Use this if auto scan does not work'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _manualController,
                    decoration: InputDecoration(
                      hintText: 'Enter MAC address',
                      errorText: _manualController.text.isEmpty || _isMacValid
                          ? null
                          : 'Invalid MAC',
                    ),
                    onChanged: (value) {
                      final valid = _macRegExp.hasMatch(value.trim());
                      setStateDialog(() => _isMacValid = valid);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                Consumer<BluetoothProvider>(
                  builder: (context, provider, _) {
                    final isBusy = !provider.canInitiateConnection;
                    final shouldEnable = _isMacValid && !isBusy;
                    return TextButton(
                      onPressed: shouldEnable
                          ? () {
                              provider.connectToDevice(_manualController.text.trim());
                              Navigator.of(context).pop();
                            }
                          : null,
                      child: isBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Connect'),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }
  
  @override
  Widget build(BuildContext context) {
    final btProvider = context.watch<BluetoothProvider>();
    final contactsProvider = context.watch<ContactsProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    _scheduleMessageFlush(btProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('BTCalls'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(themeProvider.isDarkMode ? Icons.light_mode : Icons.dark_mode),
            onPressed: () => themeProvider.toggleTheme(),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'key_management') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ManageKeysPage(),
                  ),
                );
              } else if (value == 'contacts') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ContactsScreen(),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'key_management',
                child: Text('Key management'),
              ),
              const PopupMenuItem<String>(
                value: 'contacts',
                child: Text('Contacts & sharing'),
              ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Icon(
                      btProvider.status == 'idle' ? Icons.circle : Icons.circle,
                      color: btProvider.status == 'idle' ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'Status: ${btProvider.status}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Manual Connect Button opens dialog if auto scan fails
            ElevatedButton.icon(
              onPressed: _showManualConnectDialog,
              icon: const Icon(Icons.edit),
              label: const Text('Manual Connect'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
            const SizedBox(height: 16),
            // Professional 2x2 action grid
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: 3,
              children: [
                ElevatedButton.icon(
                  onPressed: btProvider.canStartServer
                      ? () => btProvider.startServer()
                      : null,
                  icon: const Icon(FontAwesomeIcons.server),
                  label: const Text('Start Server'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: btProvider.canStopServer
                      ? () => btProvider.stopServer()
                      : null,
                  icon: const Icon(FontAwesomeIcons.stop),
                  label: const Text('Stop Server'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: btProvider.canStartScan
                      ? () => btProvider.startScan()
                      : null,
                  icon: const Icon(FontAwesomeIcons.magnifyingGlass),
                  label: const Text('Start Scan'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: btProvider.canStopScan
                      ? () => btProvider.stopScan()
                      : null,
                  icon: const Icon(FontAwesomeIcons.stop),
                  label: const Text('Stop Scan'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Devices List
            if (btProvider.devices.isEmpty)
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(FontAwesomeIcons.bluetooth, size: 100, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text('No devices found'),
                  ],
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: btProvider.devices.length,
                itemBuilder: (context, index) {
                  final Device device = btProvider.devices[index];
                  final matches = device.discoveryHint.isNotEmpty
                      ? contactsProvider.contactsForDiscoveryHint(device.discoveryHint)
                      : const [];
                  final aliasSummary = matches.isEmpty
                      ? null
                      : matches.map((contact) => contact.name).join(', ');
                  final keyPreview = matches.isEmpty
                      ? null
                      : _shortenKey(matches.first.publicKey);
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    child: Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          child: const Icon(FontAwesomeIcons.bluetooth, color: Colors.white),
                        ),
                        title: Text(device.name),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Address (ephemeral): ${device.address}'),
                            if (aliasSummary != null)
                              Text('Known as: $aliasSummary'),
                            if (keyPreview != null)
                              Text('Last key: $keyPreview'),
                            if (device.discoveryHint.isNotEmpty)
                              Text('Discovery code: ${device.discoveryHint}'),
                          ],
                        ),
                        trailing: ElevatedButton(
                          onPressed: btProvider.canInitiateConnection
                              ? () => btProvider.connectToDevice(device.address)
                              : null,
                          child: btProvider.isConnecting &&
                                  btProvider.connectedDevice?.address == device.address
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Connect'),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
          ),
        ),
      ),
    );
  }

  String _shortenKey(String key) {
    if (key.isEmpty) return 'Unknown';
    if (key.length <= 12) return key;
    return '${key.substring(0, 12)}…';
  }


}
