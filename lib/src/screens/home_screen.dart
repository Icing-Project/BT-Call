import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../providers/bluetooth_provider.dart';
import '../providers/theme_provider.dart';
import '../models/device.dart';

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
  }
  @override
  void dispose() {
    _manualController.dispose();
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
                TextButton(
                  onPressed: _isMacValid
                      ? () {
                          final btProvider = context.read<BluetoothProvider>();
                          btProvider.connectToDevice(_manualController.text.trim());
                          Navigator.of(context).pop();
                        }
                      : null,
                  child: const Text('Connect'),
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
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('BTCalls'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(themeProvider.isDarkMode ? Icons.light_mode : Icons.dark_mode),
            onPressed: () => themeProvider.toggleTheme(),
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
                  onPressed: btProvider.startServer,
                  icon: const Icon(FontAwesomeIcons.server),
                  label: const Text('Start Server'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: btProvider.stopServer,
                  icon: const Icon(FontAwesomeIcons.stop),
                  label: const Text('Stop Server'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: btProvider.startScan,
                  icon: const Icon(FontAwesomeIcons.magnifyingGlass),
                  label: const Text('Start Scan'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: btProvider.stopScan,
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
            // Decrypt Toggle
            SwitchListTile(
              title: const Text('Decrypt Audio'),
              value: btProvider.decryptEnabled,
              onChanged: btProvider.toggleDecrypt,
              secondary: const Icon(FontAwesomeIcons.lock),
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
                        subtitle: Text(device.address),
                        trailing: ElevatedButton(
                          onPressed: () => btProvider.connectToDevice(device.address),
                          child: const Text('Connect'),
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


}
