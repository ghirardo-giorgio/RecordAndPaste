// La spia dell'ascolto (icona a orecchio) deve comparire SOLO quando uno dei
// due ascolti e' acceso: se comparisse a vuoto direbbe all'utente che un
// microfono e' aperto quando non lo e'.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:record_and_paste/models/button_spec.dart';
import 'package:record_and_paste/models/daemon_state.dart';
import 'package:record_and_paste/screens/home_screen.dart';
import 'package:record_and_paste/services/locale_service.dart';
import 'package:record_and_paste/services/steno_client.dart';

StenoClient _connectedClient() {
  final client = StenoClient();
  client.status = ConnectionStatus.connected;
  client.daemonState = DaemonState.idle;
  client.dashboards = [
    Dashboard.fromJson({
      'id': 'default',
      'name': 'Stenografa',
      'rows': 1,
      'cols': 1,
      'buttons': [
        {'id': 'record', 'label': 'Registra', 'kind': 'record',
         'row': 0, 'col': 0},
      ],
    })
  ];
  return client;
}

Future<void> _pumpHome(WidgetTester tester, StenoClient client) async {
  await tester.pumpWidget(MaterialApp(
    home: HomeScreen(client: client, locale: LocaleService()),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('nessuna spia quando entrambi gli ascolti sono spenti',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final client = _connectedClient();
    client.wakeWordEnabled = false;

    await _pumpHome(tester, client);

    expect(find.byIcon(Icons.hearing), findsNothing);
  });

  testWidgets('spia presente quando ascolta il PC', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final client = _connectedClient();
    client.wakeWordEnabled = true;

    await _pumpHome(tester, client);

    expect(find.byIcon(Icons.hearing), findsOneWidget);
  });

  testWidgets('spia presente quando ascolta il telefono', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'phone_wake_word': true,
    });
    final client = _connectedClient();
    client.wakeWordEnabled = false;

    await _pumpHome(tester, client);

    expect(find.byIcon(Icons.hearing), findsOneWidget);
  });
}
