import 'package:flutter/material.dart';
import 'package:btcalls/src/services/asymmetric_crypto_service.dart';

class ManageKeysPage extends StatefulWidget {
  const ManageKeysPage({Key? key}) : super(key: key);

  @override
  _ManageKeysPageState createState() => _ManageKeysPageState();
}

class _ManageKeysPageState extends State<ManageKeysPage> {
  final AsymmetricCryptoService _cryptoService = AsymmetricCryptoService();
  List<Map<String, dynamic>> _keys = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    setState(() {
      _isLoading = true;
    });
    try {
      List<Map<String, dynamic>> keys = await _cryptoService.getAllKeys();
      setState(() {
        _keys = keys;
      });
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error loading keys: $e')));
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _generateKey() async {
    setState(() {
      _isLoading = true;
    });
    try {
      await _cryptoService.generateKeyPair();
      await _loadKeys();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Key generated successfully')));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error generating key: $e')));
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteKey(String alias) async {
    setState(() {
      _isLoading = true;
    });
    try {
      await _cryptoService.deleteKeyPair(alias);
      await _loadKeys();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Key deleted successfully')));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error deleting key: $e')));
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _viewPublicKey(String alias) async {
    try {
      final publicKey = await _cryptoService.deriveNadePublicKey(alias);
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Public Key'),
          content: SingleChildScrollView(child: Text(publicKey)),
          actions: [
            TextButton(
              child: const Text('Close'),
              onPressed: () {
                Navigator.pop(context);
              },
            )
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error retrieving public key: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Keys'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _keys.isEmpty
              ? const Center(child: Text('No keys found'))
              : ListView.builder(
                  itemCount: _keys.length,
                  itemBuilder: (context, index) {
                    final keyData = _keys[index];
                    return ListTile(
                      title: Text(keyData['label'] ?? 'No label'),
                      subtitle: Text(keyData['alias'] ?? ''),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.visibility),
                            tooltip: 'View Public Key',
                            onPressed: () => _viewPublicKey(keyData['alias']),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete),
                            tooltip: 'Delete Key',
                            onPressed: () => _deleteKey(keyData['alias']),
                          ),
                        ],
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _generateKey,
        child: const Icon(Icons.add),
        tooltip: 'Generate New Key',
      ),
    );
  }
}