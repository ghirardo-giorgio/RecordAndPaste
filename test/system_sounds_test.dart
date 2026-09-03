// I segnali acustici del riconoscimento vengono silenziati mentre si aspetta
// la frase di attivazione. L'errore da evitare a tutti i costi e' lasciare il
// telefono muto: qui si controlla che ogni silenziamento venga ripristinato.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:record_and_paste/services/system_sounds.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('record_and_paste/system_sounds');
  late List<String> chiamate;

  setUp(() async {
    chiamate = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      chiamate.add(call.method);
      return null;
    });
    // ogni test parte da zero: SystemSounds tiene un contatore statico
    while (SystemSounds.muted) {
      await SystemSounds.unmute();
    }
    chiamate.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('silenzia e ripristina una volta sola', () async {
    await SystemSounds.mute();
    expect(SystemSounds.muted, isTrue);
    await SystemSounds.unmute();
    expect(SystemSounds.muted, isFalse);
    expect(chiamate, ['mute', 'unmute']);
  });

  test('richieste ripetute non moltiplicano le chiamate native', () async {
    await SystemSounds.mute();
    await SystemSounds.mute();
    expect(chiamate, ['mute']);

    // il primo ripristino non basta: l'ascolto e' ancora in corso
    await SystemSounds.unmute();
    expect(SystemSounds.muted, isTrue);
    expect(chiamate, ['mute']);

    await SystemSounds.unmute();
    expect(SystemSounds.muted, isFalse);
    expect(chiamate, ['mute', 'unmute']);
  });

  test('un ripristino di troppo non fa danni', () async {
    await SystemSounds.unmute();
    expect(SystemSounds.muted, isFalse);
    expect(chiamate, isEmpty);
  });

  test('senza la parte nativa non resta in stato muto', () async {
    // e' il caso di iOS, dove il canale non esiste: se lo stato restasse
    // "muto" nessuno proverebbe piu' a ripristinare
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('nessuna implementazione');
    });
    await SystemSounds.mute();
    expect(SystemSounds.muted, isFalse);
  });
}
