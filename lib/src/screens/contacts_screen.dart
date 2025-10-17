import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/contact.dart';
import '../providers/bluetooth_provider.dart';
import '../providers/contacts_provider.dart';
import '../repositories/share_profile_repository.dart';
import '../services/bluetooth_audio_service.dart';
import '../services/asymmetric_crypto_service.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabController;
  final AsymmetricCryptoService _crypto = AsymmetricCryptoService();
  final ShareProfileRepository _sharePrefs = ShareProfileRepository();
  MobileScannerController? _scannerController;
  int _scannerViewId = 0;

  final TextEditingController _nameController = TextEditingController();

  bool _loadingShareData = true;
  List<Map<String, dynamic>> _availableKeys = const [];
  String? _selectedAlias;
  String _publicKey = '';
  String _discoveryHint = '';
  String? _shareError;
  bool _cameraPermissionGranted = false;
  bool _isProcessingScan = false;
  bool _scannerActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(_handleTabChange);
    _loadInitialData();
  }

  MobileScannerController _buildScannerController() {
    return MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
      facing: CameraFacing.back,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      unawaited(_stopScanner());
    } else if (state == AppLifecycleState.resumed && _tabController.index == 2 && _cameraPermissionGranted) {
      unawaited(_startScanner());
    }
  }

  Future<void> _loadInitialData() async {
    final savedName = await _sharePrefs.loadDisplayName();
    if (savedName != null && savedName.isNotEmpty) {
      _nameController.text = savedName;
    } else {
      await _prefillDisplayNameFromDevice();
    }
    final hint = (await _sharePrefs.ensureDiscoveryHint()).toUpperCase();
    await _loadKeys(preferredAlias: await _sharePrefs.loadKeyAlias());
    if (!mounted) return;
    setState(() {
      _discoveryHint = hint;
      _loadingShareData = false;
    });
  }

  Future<void> _prefillDisplayNameFromDevice() async {
    final status = await Permission.bluetoothConnect.request();
    if (!status.isGranted && !status.isLimited && !status.isProvisional) {
      return;
    }
    try {
      final info = await BluetoothAudioService.instance.getLocalDeviceInfo();
      final rawName = info['name'];
      final deviceName = rawName is String ? rawName.trim() : '';
      if (!mounted || deviceName.isEmpty) {
        return;
      }
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = deviceName;
      }
    } catch (e) {
      debugPrint('Failed to fetch local device name: $e');
    }
  }

  Future<void> _loadKeys({String? preferredAlias}) async {
    try {
      final keys = await _crypto.getAllKeys();
      if (!mounted) return;
      if (keys.isEmpty) {
        setState(() {
          _availableKeys = const [];
          _publicKey = '';
          _selectedAlias = null;
        });
        return;
      }
      String? alias = preferredAlias;
      final aliases = keys.map((key) => key['alias'] as String?).whereType<String>();
      if (alias == null || !aliases.contains(alias)) {
        alias = keys.first['alias'] as String?;
      }
      await _selectAlias(alias);
      setState(() {
        _availableKeys = keys;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _shareError = 'Unable to load keys: $e';
      });
    }
  }

  Future<void> _selectAlias(String? alias) async {
    if (alias == null) {
      setState(() {
        _selectedAlias = null;
        _publicKey = '';
      });
      return;
    }
    try {
      final key = await _crypto.getPublicKey(alias);
      if (!mounted) return;
      await _sharePrefs.saveKeyAlias(alias);
      setState(() {
        _selectedAlias = alias;
        _publicKey = key;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _shareError = 'Unable to load public key: $e';
      });
    }
  }

  void _handleTabChange() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == 2) {
      unawaited(_startScanner());
    } else {
      unawaited(_stopScanner());
    }
  }

  Future<void> _startScanner() async {
    final status = await Permission.camera.request();
    if (!status.isGranted && !status.isLimited) {
      setState(() {
        _cameraPermissionGranted = false;
      });
      return;
    }
    if (!mounted) return;
    var createdController = false;
    late MobileScannerController controller;
    setState(() {
      _cameraPermissionGranted = true;
      if (_scannerController == null) {
        _scannerController = _buildScannerController();
        _scannerActive = false;
        _scannerViewId++;
        createdController = true;
      }
      controller = _scannerController!;
    });

    if (createdController) {
      await WidgetsBinding.instance.endOfFrame;
    }

    if (_scannerActive) {
      return;
    }
    try {
      await controller.start();
      _scannerActive = true;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraPermissionGranted = false;
      });
      _scannerActive = false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to start camera: $e')),
      );
    }
  }

  Future<void> _stopScanner() async {
    final controller = _scannerController;
    if (controller == null) {
      return;
    }
    try {
      if (_scannerActive) {
        await controller.stop();
      }
    } catch (_) {
      // Ignore stop errors; controller will be recreated if needed.
    } finally {
      _scannerActive = false;
      if (!mounted) {
        controller.dispose();
        _scannerController = null;
      } else {
        setState(() {
          _scannerController = null;
          _scannerViewId++;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          controller.dispose();
        });
      }
    }
  }

  Future<void> _ensureScannerRunning() async {
    if (!_cameraPermissionGranted) {
      return;
    }
    if (_scannerController == null) {
      await _startScanner();
      return;
    }
    if (_scannerActive) {
      return;
    }
    try {
      await _scannerController!.start();
      _scannerActive = true;
    } catch (_) {
      _scannerActive = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    unawaited(_stopScanner());
    _scannerController?.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts & Sharing'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Contacts'),
            Tab(text: 'Share'),
            Tab(text: 'Scan'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _ContactsListTab(onRemove: _onRemoveContact),
          _buildShareTab(),
          _buildScanTab(),
        ],
      ),
    );
  }

  Future<bool> _onRemoveContact(Contact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete contact?'),
        content: Text('Remove ${contact.name} from your saved contacts?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return false;
    }
    await context.read<ContactsProvider>().removeContact(contact);
    if (!mounted) {
      return true;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('${contact.name} removed.')));
    return true;
  }

  Widget _buildShareTab() {
    if (_loadingShareData) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_shareError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _shareError!,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_availableKeys.isEmpty || _selectedAlias == null || _publicKey.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.key_off, size: 72),
            const SizedBox(height: 16),
            const Text(
              'No keys available to share yet. Generate a key in Key Management to get started.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.manage_accounts),
              label: const Text('Manage keys'),
            ),
          ],
        ),
      );
    }

    final theme = Theme.of(context);
    final qrPayload = jsonEncode({
      'type': 'btcalls_contact',
      'version': 2,
      'name': _effectiveDisplayName,
      'publicKey': _publicKey,
      'alias': _selectedAlias,
      'discoveryHint': _discoveryHint,
    });

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Display name', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              hintText: 'Enter the name others should see',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              _sharePrefs.saveDisplayName(value.trim());
              setState(() {});
            },
          ),
          const SizedBox(height: 20),
          Text('Discovery code', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  _discoveryHint,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              IconButton(
                tooltip: 'Regenerate',
                onPressed: () async {
                  final hint = await _sharePrefs.regenerateDiscoveryHint();
                  if (!mounted) return;
                  setState(() {
                    _discoveryHint = hint.toUpperCase();
                  });
                  if (!mounted) return;
                  context.read<BluetoothProvider>().refreshDiscoveryHint();
                },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Android now masks Bluetooth MAC addresses. Share this discovery code so trusted contacts can recognise you when you broadcast it.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          Text('Public key to share', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _selectedAlias,
            isExpanded: true,
            items: _availableKeys
                .map((key) => DropdownMenuItem<String>(
                      value: key['alias'] as String,
                      child: Text(key['label'] as String? ?? key['alias'] as String),
                    ))
                .toList(),
            onChanged: (alias) {
              if (alias == null) return;
              _selectAlias(alias);
            },
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          Center(
            child: QrImageView(
              data: qrPayload,
              version: QrVersions.auto,
              size: 240,
              backgroundColor: Colors.white,
              embeddedImageStyle: const QrEmbeddedImageStyle(size: Size(40, 40)),
            ),
          ),
          const SizedBox(height: 16),
          ExpansionTile(
            title: const Text('Public key (tap to view)'),
            children: [
              SelectableText(_publicKey, style: theme.textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScanTab() {
    if (!_cameraPermissionGranted) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.camera_alt_outlined, size: 64),
              const SizedBox(height: 16),
              const Text(
                'Grant camera access to scan a contact QR code.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _startScanner,
                child: const Text('Grant camera access'),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (_scannerController != null)
          MobileScanner(
            key: ValueKey('scanner-$_scannerViewId'),
            controller: _scannerController,
            onDetect: (capture) {
              if (_isProcessingScan) return;
              final barcode = capture.barcodes.firstOrNull;
              final raw = barcode?.rawValue;
              if (raw == null || raw.isEmpty) return;
              _handleScannedPayload(raw);
            },
          )
        else
          const ColoredBox(color: Colors.black),
        if (_isProcessingScan)
          Container(
            color: Colors.black54,
            child: const Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  Future<void> _handleScannedPayload(String raw) async {
    setState(() => _isProcessingScan = true);
    late final Contact contact;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['type'] != 'btcalls_contact') {
        throw const FormatException('Not a BTCalls contact QR code.');
      }
      final name = decoded['name'] as String? ?? 'Unknown';
      final legacyMac = decoded['mac'] as String? ?? '';
      final macsRaw = decoded['macs'] ?? decoded['macAddresses'];
      if (legacyMac.isNotEmpty || (macsRaw is List && macsRaw.isNotEmpty)) {
        debugPrint('Ignoring legacy MAC values in contact payload.');
      }
      final publicKey = decoded['publicKey'] as String? ?? '';
  final discoveryHint = (decoded['discoveryHint'] as String? ?? '').toUpperCase();
      if (publicKey.isEmpty) {
        throw const FormatException('Contact payload missing public key.');
      }
      contact = Contact(
        name: name,
        publicKey: publicKey,
        createdAt: DateTime.now(),
  discoveryHint: discoveryHint,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessingScan = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Scan failed: $e')),
      );
      return;
    }

    if (!mounted) {
      setState(() => _isProcessingScan = false);
      return;
    }

    final contactToSave = contact;
    final previewLength = contactToSave.publicKey.length > 40
        ? 40
        : contactToSave.publicKey.length;

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save contact?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Name: ${contactToSave.name}'),
            const SizedBox(height: 8),
            if (contactToSave.discoveryHint.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Discovery code: ${contactToSave.discoveryHint}'),
            ],
            const SizedBox(height: 8),
            Text(
              'Key preview: ${contactToSave.publicKey.substring(0, previewLength)}${contactToSave.publicKey.length > previewLength ? '...' : ''}',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (shouldSave == true) {
      final added =
          await context.read<ContactsProvider>().addContact(contactToSave);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added
                ? '${contactToSave.name} saved.'
                : 'Contact already exists.',
          ),
        ),
      );
    }

    setState(() => _isProcessingScan = false);
    if (_tabController.index == 2) {
      await _ensureScannerRunning();
    }
  }

  String get _effectiveDisplayName {
    final text = _nameController.text.trim();
    if (text.isNotEmpty) return text;
    if (_availableKeys.isEmpty) return 'BTCalls User';
    return 'BTCalls User';
  }
}

class _ContactsListTab extends StatelessWidget {
  const _ContactsListTab({required this.onRemove});

  final Future<bool> Function(Contact contact) onRemove;

  @override
  Widget build(BuildContext context) {
    return Consumer<ContactsProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (provider.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.people_outline, size: 72),
                  const SizedBox(height: 16),
                  Text(
                    'No contacts yet. Share your QR code or scan one to add a contact.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          );
        }

        final contacts = provider.contacts;
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: contacts.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final contact = contacts[index];
            final discoveryText = contact.discoveryHint.isNotEmpty
                ? 'Discovery code: ${contact.discoveryHint}'
                : 'Discovery code: Not provided';
            final savedText = 'Saved: ${_formatDateTime(context, contact.createdAt)}';
            final lastSeenText = contact.lastSeen == null
                ? 'Last seen: Never'
                : 'Last seen: ${_formatDateTime(context, contact.lastSeen!)}';
            final deviceText = contact.lastKnownDeviceName?.isNotEmpty == true
                ? 'Last device: ${contact.lastKnownDeviceName}'
                : null;
            return Dismissible(
              key: ValueKey('${contact.publicKey}_${contact.discoveryHint}_${contact.createdAt.toIso8601String()}'),
              direction: DismissDirection.endToStart,
              confirmDismiss: (_) => onRemove(contact),
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                color: Theme.of(context).colorScheme.error,
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              child: ListTile(
                title: Text(contact.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(discoveryText),
                    Text(savedText),
                    Text(lastSeenText),
                    if (deviceText != null) Text(deviceText),
                  ],
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy public key',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: contact.publicKey));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Copied ${contact.name}\'s public key.')),
                    );
                  },
                ),
                onTap: () {
                  showModalBottomSheet(
                    context: context,
                    builder: (context) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(contact.name, style: Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 12),
                              SelectableText(discoveryText),
                              const SizedBox(height: 12),
                              SelectableText(savedText),
                              const SizedBox(height: 12),
                              SelectableText(lastSeenText),
                              if (deviceText != null) ...[
                                const SizedBox(height: 12),
                                SelectableText(deviceText),
                              ],
                              const SizedBox(height: 12),
                              SelectableText('Public key:\n${contact.publicKey}'),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

String _formatDateTime(BuildContext context, DateTime timestamp) {
  final local = timestamp.toLocal();
  final localizations = MaterialLocalizations.of(context);
  final date = localizations.formatShortDate(local);
  final time = localizations.formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: true,
  );
  return '$date $time';
}
