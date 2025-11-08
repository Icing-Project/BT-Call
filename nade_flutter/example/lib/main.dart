import 'package:flutter/material.dart';
import 'package:nade_flutter/nade_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const NadeExampleApp());
}

class NadeExampleApp extends StatelessWidget {
  const NadeExampleApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NADE Example',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
      ),
      home: const NadeHomePage(),
    );
  }
}

class NadeHomePage extends StatefulWidget {
  const NadeHomePage({Key? key}) : super(key: key);

  @override
  State<NadeHomePage> createState() => _NadeHomePageState();
}

class _NadeHomePageState extends State<NadeHomePage> {
  bool _initialized = false;
  bool _inCall = false;
  final List<String> _eventLog = [];
  final TextEditingController _peerIdController = TextEditingController(text: 'TestPeer123');
  
  // Configuration
  final _config = const NadeConfig(
    sampleRate: 16000,
    symbolRate: 100.0,
    frequencies: [600, 900, 1200, 1500],
    codecMode: 1400,
    debugLogging: true,
  );

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    // Request necessary permissions
    await Permission.microphone.request();
    await Permission.bluetooth.request();
    await Permission.bluetoothConnect.request();
  }

  Future<void> _initialize() async {
    try {
      // Generate a dummy keypair (in production, use proper key generation)
      const dummyKeyPair = '''
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VuBCIEIE1vY2tLZXlGb3JUZXN0aW5nT25seU5vdFByb2R1Y3Rpb24=
-----END PRIVATE KEY-----
''';

      await Nade.initialize(
        identityKeyPairPem: dummyKeyPair,
        config: _config,
      );

      Nade.setEventHandler(_handleNadeEvent);

      setState(() {
        _initialized = true;
        _addLog('✅ NADE initialized successfully');
      });
    } catch (e) {
      _addLog('❌ Initialization failed: $e');
    }
  }

  void _handleNadeEvent(NadeEvent event) {
    setState(() {
      String emoji = '📡';
      switch (event.type) {
        case NadeEventType.handshakeStarted:
          emoji = '🤝';
          break;
        case NadeEventType.handshakeSuccess:
          emoji = '✅';
          break;
        case NadeEventType.sessionEstablished:
          emoji = '🔒';
          break;
        case NadeEventType.error:
          emoji = '❌';
          break;
        case NadeEventType.fecCorrection:
          emoji = '🔧';
          break;
        case NadeEventType.syncLost:
          emoji = '⚠️';
          break;
        case NadeEventType.syncAcquired:
          emoji = '🎯';
          break;
        default:
          break;
      }
      
      _addLog('$emoji ${event.type.name}: ${event.message}');
    });
  }

  void _addLog(String message) {
    setState(() {
      _eventLog.insert(0, '[${DateTime.now().toIso8601String().substring(11, 19)}] $message');
      if (_eventLog.length > 50) {
        _eventLog.removeLast();
      }
    });
  }

  Future<void> _startCall() async {
    try {
      final success = await Nade.startCall(
        peerId: _peerIdController.text,
        transport: 'bluetooth',
      );

      if (success) {
        setState(() {
          _inCall = true;
          _addLog('📞 Call started with ${_peerIdController.text}');
        });
      } else {
        _addLog('❌ Failed to start call');
      }
    } catch (e) {
      _addLog('❌ Start call error: $e');
    }
  }

  Future<void> _stopCall() async {
    try {
      await Nade.stopCall();
      setState(() {
        _inCall = false;
        _addLog('📴 Call ended');
      });
    } catch (e) {
      _addLog('❌ Stop call error: $e');
    }
  }

  Future<void> _checkPeerCapability() async {
    try {
      final capable = await Nade.isPeerNadeCapable(_peerIdController.text);
      _addLog(capable
          ? '✅ Peer ${_peerIdController.text} supports NADE'
          : '⚠️ Peer ${_peerIdController.text} may not support NADE');
    } catch (e) {
      _addLog('❌ Capability check error: $e');
    }
  }

  Future<void> _getStatus() async {
    try {
      final status = await Nade.getStatus();
      _addLog('📊 Status: $status');
    } catch (e) {
      _addLog('❌ Get status error: $e');
    }
  }

  @override
  void dispose() {
    _peerIdController.dispose();
    Nade.shutdown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NADE Example'),
        actions: [
          IconButton(
            icon: Icon(_initialized ? Icons.check_circle : Icons.error),
            color: _initialized ? Colors.green : Colors.red,
            onPressed: _initialized ? null : _initialize,
          ),
        ],
      ),
      body: Column(
        children: [
          // Controls
          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _peerIdController,
                    decoration: const InputDecoration(
                      labelText: 'Peer ID',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                    enabled: !_inCall,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: Icon(_inCall ? Icons.call_end : Icons.call),
                          label: Text(_inCall ? 'End Call' : 'Start Call'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _inCall ? Colors.red : Colors.green,
                            padding: const EdgeInsets.all(16),
                          ),
                          onPressed: !_initialized
                              ? null
                              : (_inCall ? _stopCall : _startCall),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.search),
                        label: const Text('Check'),
                        onPressed: !_initialized || _inCall ? null : _checkPeerCapability,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.info),
                    label: const Text('Get Status'),
                    onPressed: !_initialized ? null : _getStatus,
                  ),
                ],
              ),
            ),
          ),
          
          // Configuration display
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Configuration', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('Sample Rate: ${_config.sampleRate} Hz', style: const TextStyle(fontSize: 12)),
                    Text('Symbol Rate: ${_config.symbolRate} baud', style: const TextStyle(fontSize: 12)),
                    Text('Frequencies: ${_config.frequencies.join(", ")} Hz', style: const TextStyle(fontSize: 12)),
                    Text('Codec Mode: ${_config.codecMode} bps', style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 8),
          
          // Event log
          Expanded(
            child: Card(
              margin: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withOpacity(0.1),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.event_note, size: 20),
                        const SizedBox(width: 8),
                        const Text('Event Log', style: TextStyle(fontWeight: FontWeight.bold)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.clear_all, size: 20),
                          onPressed: () => setState(() => _eventLog.clear()),
                          tooltip: 'Clear log',
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _eventLog.isEmpty
                        ? const Center(
                            child: Text(
                              'No events yet.\nInitialize NADE and start a call to see events.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _eventLog.length,
                            itemBuilder: (context, index) {
                              return ListTile(
                                dense: true,
                                title: Text(
                                  _eventLog[index],
                                  style: const TextStyle(
                                    fontFamily: 'Courier',
                                    fontSize: 12,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: !_initialized
          ? FloatingActionButton.extended(
              onPressed: _initialize,
              icon: const Icon(Icons.power_settings_new),
              label: const Text('Initialize NADE'),
            )
          : null,
    );
  }
}
