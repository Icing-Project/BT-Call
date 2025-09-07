import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/providers/bluetooth_provider.dart';
import 'src/providers/theme_provider.dart';
import 'src/theme/app_theme.dart';
import 'src/screens/home_screen.dart';
import 'src/services/four_fsk_service.dart';
import 'src/services/bluetooth_audio_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // set up 4-FSK modem and Bluetooth audio service singleton
  BluetoothAudioService.initialize(
    FourFskService(
      sampleRate: 8000,
      symbolRate: 100.0,
      frequencies: [1200, 1600, 2000, 2400],
    ),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BluetoothProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, child) {
          return MaterialApp(
            title: 'BTCalls Demo',
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            home: const HomeScreen(),
          );
        },
      ),
    );
  }
}
