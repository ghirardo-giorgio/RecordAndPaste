// Regressione: in una dashboard senza pulsanti le celle libere si vedevano
// ma non ricevevano i tocchi, perche' lo Stack della griglia — avendo solo
// figli posizionati — collassava a dimensione zero.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:record_and_paste/models/button_spec.dart';
import 'package:record_and_paste/models/daemon_state.dart';
import 'package:record_and_paste/screens/home_screen.dart';
import 'package:record_and_paste/services/locale_service.dart';
import 'package:record_and_paste/services/steno_client.dart';

void _stubWakelock() {
  const codec = StandardMessageCodec();
  for (final method in ['toggle', 'isEnabled']) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.'
          'WakelockPlusApi.$method',
          (message) async => codec.encodeMessage(<Object?>[false]),
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cella vuota di una dashboard senza pulsanti apre il dialogo',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _stubWakelock();
    final client = StenoClient();
    client.status = ConnectionStatus.connected;
    client.daemonState = DaemonState.idle;
    client.dashboards = [
      Dashboard.fromJson({
        'id': 'detta', 'name': 'Detta', 'rows': 1, 'cols': 1, 'buttons': [],
      }),
    ];

    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(client: client, locale: LocaleService()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // senza host/token salvati HomeScreen apre la schermata di connessione:
    // si richiude, come nei golden
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    // modalita' modifica
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    // la cella vuota mostra il "+"
    expect(find.byIcon(Icons.add), findsWidgets,
        reason: 'la cella libera deve essere disegnata');

    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'il tocco deve aprire il dialogo di creazione');
  });
}
