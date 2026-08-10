// Screenshot della schermata principale renderizzati senza telefono ne'
// emulatore: il test monta [HomeScreen] con uno [StenoClient] riempito a
// mano (nessuna connessione al demone) e salva i PNG in test/goldens/ con
// `flutter test --update-goldens test/screenshots_test.dart`.
//
// Servono a guardare la UI mentre la si modifica; il confronto automatico
// (`flutter test` senza --update-goldens) e' un effetto collaterale utile,
// ma i PNG dipendono dalle font di sistema, quindi una differenza non e'
// necessariamente una regressione.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:record_and_paste/models/button_spec.dart';
import 'package:record_and_paste/models/daemon_state.dart';
import 'package:record_and_paste/screens/home_screen.dart';
import 'package:record_and_paste/services/locale_service.dart';
import 'package:record_and_paste/services/steno_client.dart';

/// Dashboard di esempio: un microfono, un comando vocale IA, il nuovo
/// "incolla ultimo" e due scorciatoie (una singola e una macro), cosi' lo
/// screenshot mostra tutti i tipi di cella.
Dashboard _demoDashboard() => Dashboard.fromJson({
  'id': 'default',
  'name': 'Stenografa',
  'rows': 3,
  'cols': 2,
  'buttons': [
    {'id': 'record', 'label': 'Registra', 'kind': 'record', 'row': 0, 'col': 0},
    {
      'id': 'ai',
      'label': 'Comando vocale',
      'kind': 'ai_command',
      'row': 0,
      'col': 1,
    },
    {
      'id': 'incollaultimo',
      'label': 'Incolla ultimo',
      'kind': 'paste_last',
      'row': 1,
      'col': 0,
    },
    {
      'id': 'copia',
      'label': 'Copia',
      'kind': 'keys',
      'combo': 'ctrl+c',
      'row': 1,
      'col': 1,
      'color': '#1e88e5',
      'icon': 'content_copy',
    },
    {
      'id': 'salvaecompila',
      'label': 'Salva e compila',
      'kind': 'macro',
      'combos': ['ctrl+s', 'ctrl+shift+b'],
      'delay_ms': 120,
      'row': 2,
      'col': 0,
      'color': '#43a047',
      'icon': 'playlist_play',
    },
  ],
});

/// Client gia' "collegato", senza toccare la rete: [StenoClient.connect] non
/// viene mai chiamato, si valorizzano direttamente i campi che la UI legge.
StenoClient _connectedClient({
  DaemonState state = DaemonState.idle,
  List<Dashboard>? dashboards,
}) {
  final client = StenoClient();
  client.status = ConnectionStatus.connected;
  client.daemonState = state;
  client.dashboards = dashboards ?? [_demoDashboard()];
  return client;
}

Future<void> _pumpHome(WidgetTester tester, StenoClient client) async {
  // formato telefono: il layout e' pensato a schermo intero verticale
  tester.view.physicalSize = const Size(1080, 2160);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        // come nell'app vera, ma nominata esplicitamente perche' nei test
        // la font di default e' quella segnaposto (vedi _loadRealFonts)
        fontFamily: 'Roboto',
      ),
      home: HomeScreen(client: client, locale: LocaleService()),
    ),
  );
  // le preferenze e le impostazioni di connessione arrivano da
  // SharedPreferences (asincrone): senza host/token salvati HomeScreen apre
  // da sola la schermata di connessione, che qui si richiude subito. E' il
  // modo piu' semplice per non far partire nessuna connessione vera (che
  // lascerebbe pendente il timer di timeout della socket).
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  navigator.pop();
  await tester.pumpAndSettle();
}

/// Carica le font vere (Roboto e le icone Material) dalla cache del Flutter
/// SDK: senza, i test rendono ogni glifo come un rettangolo pieno e gli
/// screenshot diventano illeggibili. Il percorso arriva da FLUTTER_ROOT, che
/// `flutter test` valorizza; se manca si rinuncia alle font invece di far
/// fallire il test.
Future<void> _loadRealFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null || root.isEmpty) return;
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return;

  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final name in files) {
      final file = File('${dir.path}/$name');
      if (!file.existsSync()) continue;
      loader.addFont(
        file.readAsBytes().then((b) => ByteData.view(b.buffer)),
      );
    }
    await loader.load();
  }

  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
  await load('Roboto', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]);
}

/// Forza la decodifica delle icone gia' presenti nel client: il framework di
/// test non fa girare il caricamento asincrono delle immagini, quindi senza
/// questo passaggio i golden le mostrerebbero vuote.
Future<void> _precacheAppIcons(WidgetTester tester, StenoClient client) async {
  final context = tester.element(find.byType(HomeScreen));
  for (final bytes in client.appIcons.values) {
    if (bytes == null) continue;
    await tester.runAsync(() => precacheImage(MemoryImage(bytes), context));
  }
  await tester.pump();
}

/// Il wakelock e' un plugin nativo: senza un telefono vero il canale non
/// esiste e la chiamata in initState fa fallire il test. Qui basta che
/// risponda "fatto".
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

  setUpAll(_loadRealFonts);

  setUp(() {
    // nessun host/token salvato: cosi' l'app non apre nessuna socket vera
    // (vedi _pumpHome per la schermata di connessione che ne consegue)
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _stubWakelock();
  });

  testWidgets('griglia a riposo', (tester) async {
    final client = _connectedClient();
    await _pumpHome(tester, client);

    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('goldens/home_idle.png'),
    );
  });

  testWidgets('registrazione in corso: gli altri microfoni sono bloccati', (
    tester,
  ) async {
    final client = _connectedClient();
    await _pumpHome(tester, client);

    // tocco sul microfono: prenota la sessione (vedi _claimMicSession)
    await tester.tap(find.byIcon(Icons.mic_none));
    await tester.pump();
    client.daemonState = DaemonState.recording;
    client.notifyListeners();
    // due frame: il primo avvia l'AnimatedContainer, il secondo lo trova a
    // fine corsa (altrimenti lo screenshot coglie i colori di partenza)
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('goldens/home_recording.png'),
    );
  });

  testWidgets('pulsanti di dimensioni diverse sopra l\'icona della app', (
    tester,
  ) async {
    final client = _connectedClient(
      dashboards: [
        Dashboard.fromJson({
          'id': 'brave',
          'name': 'Brave',
          'rows': 3,
          'cols': 3,
          'app_id': '/usr/share/applications/brave-browser.desktop',
          'buttons': [
            // largo il doppio: il pulsante che si preme piu' spesso
            {'id': 'nuovascheda', 'label': 'Nuova scheda', 'kind': 'keys',
             'combo': 'ctrl+t', 'row': 0, 'col': 0, 'col_span': 2,
             'color': '#2681a8', 'icon': 'open_in_new'},
            {'id': 'chiudi', 'label': 'Chiudi', 'kind': 'keys',
             'combo': 'ctrl+w', 'row': 0, 'col': 2, 'color': '#e1543f',
             'icon': 'close'},
            // alto il doppio
            {'id': 'record', 'label': 'Registra', 'kind': 'record',
             'row': 1, 'col': 0, 'row_span': 2},
            {'id': 'cerca', 'label': 'Cerca', 'kind': 'keys',
             'combo': 'ctrl+f', 'row': 1, 'col': 1, 'color': '#7c8c3c',
             'icon': 'search'},
            // avvia applicazione: mostra l'icona vera dell'app, non il razzo
            {'id': 'apribrave', 'label': 'Apri Brave', 'kind': 'launch',
             'app_id': '/usr/share/applications/brave-browser.desktop',
             'app_name': 'Brave', 'row': 1, 'col': 2, 'color': '#c8891e'},
            // largo due celle in fondo
            {'id': 'incollaultimo', 'label': 'Incolla ultimo',
             'kind': 'paste_last', 'row': 2, 'col': 1, 'col_span': 2,
             'color': '#5d6a75', 'icon': 'content_paste'},
          ],
        }),
      ],
    );
    client.appIcons['/usr/share/applications/brave-browser.desktop'] =
        Uint8List.fromList(
          base64Decode(
            File('test/fixtures_app_icon.b64').readAsStringSync().trim(),
          ),
        );

    await _pumpHome(tester, client);
    // nei widget test le immagini non si decodificano da sole: senza questo
    // lo screenshot mostrerebbe lo sfondo vuoto (nell'app vera il
    // caricamento asincrono avviene e basta)
    await _precacheAppIcons(tester, client);

    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('goldens/home_app_icon.png'),
    );
  });

  testWidgets('controlli dei video in riproduzione sul PC', (tester) async {
    final client = _connectedClient();
    await _pumpHome(tester, client);

    // due flussi: uno in riproduzione (icona di pausa) e uno gia' fermato
    // dal telefono (icona di play, spenta)
    client.players = const [
      MediaPlayerInfo(
        id: 'org.mpris.MediaPlayer2.brave.instance1',
        name: 'Brave',
        // titolo lungo come quelli veri di YouTube: deve troncarsi con i
        // puntini invece di spingere l'icona fuori schermo
        title: '(405) Russia Got TERRIBLE News Today - YouTube',
        playing: true,
      ),
      MediaPlayerInfo(
        id: 'org.mpris.MediaPlayer2.vlc',
        name: 'Vlc',
        title: 'lezione-3.mp4',
        playing: false,
      ),
    ];
    client.notifyListeners();
    await tester.pump();

    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('goldens/home_players.png'),
    );
  });

  testWidgets('opzioni della dashboard', (tester) async {
    final client = _connectedClient();
    await _pumpHome(tester, client);

    // il nome in cima apre le opzioni, ma solo in modalita' modifica
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await tester.tap(find.text('Stenografa'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/dashboard_options.png'),
    );
  });

  testWidgets('impostazioni della dashboard (rinomina)', (tester) async {
    final client = _connectedClient();
    await _pumpHome(tester, client);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await tester.tap(find.text('Stenografa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Impostazioni'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/dashboard_settings.png'),
    );
  });

  testWidgets('creazione di una dashboard dal telefono', (tester) async {
    final client = _connectedClient();
    await _pumpHome(tester, client);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    // pulsante dedicato nella barra laterale della modalita' modifica
    await tester.tap(find.byIcon(Icons.add_box_outlined).first);
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/dashboard_new.png'),
    );
  });

  testWidgets('editor del pulsante (pressione prolungata)', (tester) async {
    final client = _connectedClient();
    await _pumpHome(tester, client);

    // l'editor si apre solo in modalita' modifica
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await tester.longPress(find.text('Salva e compila'));
    await tester.pump(const Duration(milliseconds: 500));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/button_editor.png'),
    );
  });
}
