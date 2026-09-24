// Il microfono del telefono al posto di quello del PC: il telefono registra,
// il PC trascrive con la sua scheda grafica. Serve quando il microfono del PC
// e' occupato da un'altra applicazione.
//
// Da non confondere con phone_transcription_test.dart, dove e' il telefono a
// trascrivere: li' viaggia il testo, qui l'audio.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:record_and_paste/models/connection_settings.dart';
import 'package:record_and_paste/models/daemon_state.dart';
import 'package:record_and_paste/services/phone_microphone.dart';
import 'package:record_and_paste/services/steno_client.dart';

Uint8List _pcm(int length) =>
    Uint8List.fromList(List.generate(length, (i) => i % 256));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioChunker', () {
    test('non consegna niente finche\' il blocco non e\' pieno', () {
      final consegnati = <Uint8List>[];
      final chunker = AudioChunker(100, consegnati.add);

      chunker.add(_pcm(40));
      chunker.add(_pcm(40));

      expect(consegnati, isEmpty);
      expect(chunker.pending, 80);
    });

    test('consegna un blocco per volta, della dimensione richiesta', () {
      final consegnati = <Uint8List>[];
      final chunker = AudioChunker(100, consegnati.add);

      // un frammento solo che ne vale due e mezzo: il plugin li consegna di
      // dimensione variabile, non allineati al blocco
      chunker.add(_pcm(250));

      expect(consegnati.length, 2);
      expect(consegnati.every((c) => c.length == 100), isTrue);
      expect(chunker.pending, 50);
    });

    test('l\'audio non si perde ne\' si duplica', () {
      final consegnati = <int>[];
      final chunker = AudioChunker(100, (c) => consegnati.addAll(c));
      final originale = _pcm(333);

      chunker.add(originale);
      chunker.flush();

      expect(consegnati, originale.toList());
    });

    test('flush consegna anche l\'ultimo pezzo, incompleto', () {
      // e' la fine della frase: troncarla vorrebbe dire perdere le ultime
      // parole di ogni dettatura
      final consegnati = <Uint8List>[];
      final chunker = AudioChunker(100, consegnati.add);

      chunker.add(_pcm(130));
      expect(consegnati.length, 1);
      chunker.flush();

      expect(consegnati.length, 2);
      expect(consegnati.last.length, 30);
    });

    test('flush a buffer vuoto non consegna un blocco vuoto', () {
      final consegnati = <Uint8List>[];
      final chunker = AudioChunker(100, consegnati.add);

      chunker.add(_pcm(100));
      chunker.flush();

      expect(consegnati.length, 1);
    });

    test('un decimo di secondo di audio per blocco', () {
      // 16000 campioni al secondo, 2 byte l'uno: il demone si aspetta questo
      // formato e il conto deve tornare con quello di pw-record
      expect(chunkBytes, 3200);
    });
  });

  group('comandi verso il demone', () {
    late ServerSocket server;
    late StenoClient client;
    late Stream<String> righe;

    late Socket conn;

    setUp(() async {
      // nessun certificato fissato: il client provera' prima TLS e poi, non
      // trovandolo, ricadra' sul canale in chiaro (vedi openDaemonConnection)
      SharedPreferences.setMockInitialValues({});
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final connessioni = StreamIterator<Socket>(server);
      client = StenoClient();
      client.connect(
        ConnectionSettings(
          host: server.address.address,
          port: server.port,
          token: 'segreto',
        ),
      );
      // il primo tentativo e' TLS: chiudendolo subito l'handshake fallisce
      // senza far scadere i cinque secondi di timeout
      await connessioni.moveNext();
      connessioni.current.destroy();
      await connessioni.moveNext();
      conn = connessioni.current;
      righe = utf8.decoder
          .bind(conn)
          .transform(const LineSplitter())
          .asBroadcastStream();
      // il client si presenta con il token e aspetta il via libera prima di
      // mandare qualsiasi altro comando
      expect(jsonDecode(await righe.first), {
        'cmd': 'auth',
        'token': 'segreto',
      });
      conn.write('${jsonEncode({'type': 'auth', 'ok': true})}\n');
      await conn.flush();
      while (client.status != ConnectionStatus.connected) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });

    tearDown(() async {
      client.disconnect();
      conn.destroy();
      await server.close();
    });

    test('il PC viene avvisato che a registrare e\' il telefono', () async {
      client.pressButtonWithPhoneMic('record');

      expect(jsonDecode(await righe.first), {
        'cmd': 'button',
        'id': 'record',
        'mic': 'phone',
      });
    });

    test('l\'avvio a voce resta riconoscibile', () async {
      // il demone ne ha bisogno per togliere le frasi di attivazione dal
      // testo trascritto
      client.pressButtonWithPhoneMic('record', byVoice: true);

      expect(jsonDecode(await righe.first), {
        'cmd': 'button',
        'id': 'record',
        'mic': 'phone',
        'source': 'wake',
      });
    });

    test('l\'audio arriva al PC senza perdere un byte', () async {
      final audio = _pcm(3200);

      client.sendAudioChunk(audio);

      final msg = jsonDecode(await righe.first) as Map<String, dynamic>;
      expect(msg['cmd'], 'audio');
      expect(base64Decode(msg['data'] as String), audio);
    });

    test('i blocchi arrivano nell\'ordine in cui sono stati registrati',
        () async {
      // e' quello che rende superfluo un numero di sequenza: la connessione
      // e' una sola e conserva l'ordine
      final ricevuti = <int>[];
      final inAscolto = righe.take(3).forEach((riga) {
        final msg = jsonDecode(riga) as Map<String, dynamic>;
        ricevuti.addAll(base64Decode(msg['data'] as String));
      });

      client.sendAudioChunk(Uint8List.fromList([1, 2]));
      client.sendAudioChunk(Uint8List.fromList([3, 4]));
      client.sendAudioChunk(Uint8List.fromList([5, 6]));
      await inAscolto;

      expect(ricevuti, [1, 2, 3, 4, 5, 6]);
    });

    test('senza connessione l\'audio non va da nessuna parte', () async {
      // il pulsante puo' restare premuto mentre la rete cade: il client non
      // deve accumulare ne' sollevare
      client.disconnect();
      expect(() => client.sendAudioChunk(_pcm(3200)), returnsNormally);
    });
  });
}
