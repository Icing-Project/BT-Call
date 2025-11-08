import 'package:flutter/material.dart';
import 'package:nade_flutter/nade_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const NadeTestApp());
}

class NadeTestApp extends StatelessWidget {
  const NadeTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NADE Test',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const NadeTestScreen(),
    );
  }
}

class NadeTestScreen extends StatefulWidget {
  const NadeTestScreen({super.key});

  @override
  State<NadeTestScreen> createState() => _NadeTestScreenState();
}

class _NadeTestScreenState extends State<NadeTestScreen> {
  String _status = 'Not initialized';
  bool _inCall = false;
  String _logs = '';

  @override
  void initState() {
    super.initState();
    _initNade();
  }

  Future<void> _initNade() async {
    // Request permissions
    await Permission.microphone.request();
    await Permission.bluetooth.request();
    await Permission.bluetoothConnect.request();

    try {
      // Initialize NADE
      await Nade.initialize(
        identityKeypairPem: _generateDummyKeypair(),
        config: NadeConfig(
          sampleRate: 16000,
          symbolRate: 100.0,
          frequencies: [600, 900, 1200, 1500],
          fecStrength: 32,
          codecMode: 1400,
          debugLogging: true,
        ),
      );

      // Set event handler
      Nade.setEventHandler((event) {
        setState(() {
          _logs += '${DateTime.now()}: $event\n';
        });
      });

      setState(() {
        _status = 'Initialized';
        _logs += 'NADE initialized successfully\n';
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
        _logs += 'Error: $e\n';
      });
    }
  }

  Future<void> _startCall() async {
    try {
      await Nade.startCall(peerId: 'test-peer', transport: 'bluetooth');
      setState(() {
        _inCall = true;
        _status = 'In call';
        _logs += 'Call started\n';
      });
    } catch (e) {
      setState(() {
        _logs += 'Start call error: $e\n';
      });
    }
  }

  Future<void> _stopCall() async {
    try {
      await Nade.stopCall();
      setState(() {
        _inCall = false;
        _status = 'Call stopped';
        _logs += 'Call stopped\n';
      });
    } catch (e) {
      setState(() {
        _logs += 'Stop call error: $e\n';
      });
    }
  }

  String _generateDummyKeypair() {
    // In production, generate real Ed25519 keypair
    return '''-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIE1234567890abcdefghijklmnopqrstuvwxyzABCDEF
-----END PRIVATE KEY-----''';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NADE Test App'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Status: $_status',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text('In call: ${_inCall ? "Yes" : "No"}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _inCall ? null : _startCall,
              icon: const Icon(Icons.call),
              label: const Text('Start Call'),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _inCall ? _stopCall : null,
              icon: const Icon(Icons.call_end),
              label: const Text('Stop Call'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            const Text('Logs:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4),
                  color: Colors.grey[100],
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _logs.isEmpty ? 'No logs yet' : _logs,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (_inCall) {
      Nade.stopCall();
    }
    super.dispose();
  }
}
