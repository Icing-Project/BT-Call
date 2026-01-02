import 'package:flutter/material.dart';
import 'package:nade_flutter/nade_flutter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: ExampleHome(),
    );
  }
}

class ExampleHome extends StatefulWidget {
  const ExampleHome({super.key});

  @override
  State<ExampleHome> createState() => _ExampleHomeState();
}

class _ExampleHomeState extends State<ExampleHome> {
  String _lastEvent = 'No events received yet';

  @override
  void initState() {
    super.initState();
    Nade.setEventHandler((event) {
      setState(() {
        _lastEvent = 'Event: \'${event['type'] ?? 'unknown'}\'';
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NADE Flutter Example'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This page only demonstrates how to register for NADE events. '
              'For a full call flow you must supply a 32-byte identity key seed '
              'and peer public keys before starting audio transport.',
            ),
            const SizedBox(height: 24),
            Text(_lastEvent),
          ],
        ),
      ),
    );
  }
}
