// Quando il PC non puo' usare la GPU, a trascrivere e' il telefono: il client
// deve accorgersene da quello che il demone dichiara nella configurazione.
import 'package:flutter_test/flutter_test.dart';

import 'package:record_and_paste/services/steno_client.dart';

void main() {
  test('con la GPU il PC trascrive da se\'', () {
    final client = StenoClient();
    expect(client.modelDevice, 'cuda');
    expect(client.pcTranscriptionIsSlow, isFalse);
  });

  test('senza GPU la trascrizione del PC e\' considerata lenta', () {
    final client = StenoClient();
    client.modelDevice = 'cpu';
    expect(client.pcTranscriptionIsSlow, isTrue);
  });
}
