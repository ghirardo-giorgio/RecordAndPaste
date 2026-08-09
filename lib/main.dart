import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/locale_service.dart';
import 'services/steno_client.dart';

void main() {
  runApp(RecordAndPasteApp());
}

class RecordAndPasteApp extends StatelessWidget {
  RecordAndPasteApp({super.key});

  final StenoClient _client = StenoClient();
  final LocaleService _locale = LocaleService();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stenografa remota',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(client: _client, locale: _locale),
    );
  }
}
