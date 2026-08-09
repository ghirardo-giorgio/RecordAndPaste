// Riproduce l'avvio dell'app con un video gia' in riproduzione sul PC.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:record_and_paste/models/button_spec.dart';
import 'package:record_and_paste/models/daemon_state.dart';
import 'package:record_and_paste/screens/home_screen.dart';
import 'package:record_and_paste/services/locale_service.dart';
import 'package:record_and_paste/services/steno_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('icona presente se il player esiste gia\' al primo build',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
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
    // il player c'e' gia' PRIMA che la schermata venga costruita
    client.players = const [
      MediaPlayerInfo(id: 'brave', name: 'Brave', title: 'Un video',
          playing: true),
    ];

    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(client: client, locale: LocaleService()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
  });
}
